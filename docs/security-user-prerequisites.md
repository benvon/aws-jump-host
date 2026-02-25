# IAM Role Prerequisites for `aws ssm start-session`

## Purpose

This is the handoff document for AWS Security/IAM and Linux user provisioning teams. It defines the assumptions and prerequisites required for an IAM role to successfully execute `aws ssm start-session` to these jump hosts.

## Platform Assumptions

1. Jump host Linux users are provisioned by this platform's Ansible workflow (`./scripts/orchestrate.sh configure ...` or `apply`).
2. Jump hosts are tagged by Terraform with:
   - `JumpHost=true`
   - `AccessProfile=<profile>`
3. Session access enforcement is external (IAM Identity Center + IAM policy conditions).

## Success Criteria

An operator assuming an approved IAM role can run:

```bash
aws ssm start-session --target <instance-id>
```

and:

1. Session opens only to authorized jump hosts.
2. Session runs under the intended OS user model configured by your org.
3. Session activity is logged to the expected CloudWatch log group.

## Prerequisites Checklist (Security/IAM)

1. IAM Identity Center assignment exists for the operator role.
2. Role policy allows Session Manager actions on approved targets.
3. ABAC conditions are enforced using jump host tags and principal attributes.
4. Session Manager account settings are configured (Run As + CloudWatch logging).
5. Required private connectivity to SSM/Logs/KMS APIs is available.

## 1) IAM Role Policy Prerequisites

The IAM role used by operators must allow:

- `ssm:StartSession`
- `ssm:ResumeSession`
- `ssm:TerminateSession`
- `ssm:GetDocument`
- `ssm:DescribeDocument`
- `ssm:DescribeInstanceInformation`
- `ec2:DescribeInstances`

Use the provided starter template and adapt it centrally:

- `policy-templates/ssm-access-example.json`

### Required ABAC Conditions

Restrict start session to jump hosts and approved access profile matches:

- `ssm:resourceTag/JumpHost == "true"`
- `ssm:resourceTag/AccessProfile == ${aws:PrincipalTag/AccessProfile}` (or equivalent central mapping)

## 2) Session Manager Account Settings Prerequisites

These service settings must be configured externally per account/region:

- `/ssm/sessionmanager/enableRunAs = true`
- `/ssm/sessionmanager/enableCloudWatchLogging = true`
- `/ssm/sessionmanager/cloudWatchLogGroupName = /aws/ssm/jump-host/<env>/<subenv>/<region>`

This repo validates these settings via:

```bash
scripts/preflight_ssm_compliance.sh --region <region> --expected-log-group <name>
```

## 3) Target Instance Prerequisites

The target EC2 instance must be:

1. Managed by SSM (online as a managed instance).
2. Reachable to SSM control/data channels (via VPC endpoints or approved egress).
3. Tagged for ABAC enforcement (`JumpHost`, `AccessProfile`).

Private endpoint set required for isolated subnets:

- `ssm`
- `ssmmessages`
- `ec2messages`
- `logs`
- `kms` (if needed for encryption workflows)

## 4) Linux User Provisioning Prerequisites

Security/User provisioning teams must provide authoritative user declarations (external vars file) using:

- `ansible/vars-schema.example.yml`

Required user fields:

- `username`
- `groups`
- `sudo_profile` (`none|ops|admin`)

Optional:

- `state`
- `shell`
- `home`

Platform behavior:

- Managed users are reconciled authoritatively.
- Undeclared managed users are disabled/removed from groups.
- Passwords are locked; SSH keys are not provisioned by this platform.

## 5) Run As Model Clarification

This repository does **not** map IAM principals to specific Linux usernames. That mapping/enforcement is external.

To avoid session failures and unexpected identity behavior, Security/IAM must ensure the organization's Session Manager Run As policy is compatible with users provisioned by this platform.

## 6) Handoff Deliverables Required From Security/User Teams

Provide to platform operators:

1. AccessProfile taxonomy and principal mapping rules.
2. Confirmation that Session Manager service settings are configured in each target account/region.
3. Role/policy artifacts used for `start-session` authorization.
4. Approved location and ownership model for authoritative user vars.
5. Logging/KMS access model for session log consumers.

## 7) Pre-Go-Live Validation

1. Run preflight check in each target region/account.
2. Verify authorized role can start session to allowed hosts.
3. Verify unauthorized role is denied by ABAC conditions.
4. Verify sessions land in the expected CloudWatch log group.
5. Verify configured Linux users are present and usable per org Run As policy.
