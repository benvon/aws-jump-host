# IAM Prerequisites for `aws ssm start-session`

## Purpose

This document is for AWS Security/IAM teams only. It defines what must exist so an IAM role can successfully run:

```bash
aws ssm start-session --target <instance-id>
```

## Boundary

This platform already handles:

- target instance SSM readiness and connectivity prerequisites
- Linux user provisioning on jump hosts

Security/IAM teams are responsible for identity, IAM authorization, and Session Manager account settings.

If central management is not available yet, this repository can temporarily self-manage the required Session Manager settings via Terraform/Terragrunt (`ssm-self-management` stack) using `scripts/orchestrate.sh --ssm-self-management`.

The same `ssm-self-management` stack can also self-manage a role allowlist by attaching inline IAM policies to explicitly listed IAM role ARNs.
For `AWSReservedSSO_*` roles, direct IAM mutation is blocked; use the stack's generated policy document output and apply it in the IAM Identity Center Permission Set instead.

Helper to export generated policy JSON for a role ARN:

```bash
./scripts/export_ssm_allowlist_policy.sh \
  --terragrunt-dir live/<env>/<subenv>/<region>/ssm-self-management \
  --role-arn <iam-role-arn> \
  --output /tmp/ssm-allowlist-policy.json
```

## Required IAM Role Permissions

The operator role must allow:

- `ssm:StartSession`
- `ssm:ResumeSession`
- `ssm:TerminateSession`
- `ssm:GetDocument`
- `ssm:DescribeDocument`
- `ssm:DescribeInstanceInformation`
- `ec2:DescribeInstances`

Starter template in this repo:

- `policy-templates/ssm-access-example.json`

## Required Access Scoping (ABAC)

The role should be scoped to jump hosts using instance tags on **StartSession**:

- `ssm:resourceTag/JumpHost == "true"`
- `ssm:resourceTag/AccessProfile == ${aws:PrincipalTag/AccessProfile}` using **`StringEquals`** (see `policy-templates/ssm-access-example.json`)

The principal must carry an `AccessProfile` tag with **exactly one** value (role tag or session tag, per your federation model). Do not use `ForAnyValue:StringEquals` for this pair; it can match unintended profiles when multiple tag values appear in the request context.

**ResumeSession / TerminateSession** in the example policy are limited to session ARNs `.../session/${aws:username}-*`. The `aws:username` value depends on identity type: for an IAM user it is the user name; for `sts:AssumeRole` it is typically the **role session name** (often the federated user identifier). Confirm the resulting session ID prefix in your environment with a test session.

**StartSession** remains constrained by instance tags; operators cannot start sessions on instances whose `AccessProfile` tag does not match their principal tag.

## Required IAM-to-Linux User Mapping

If principal-to-Linux-user mapping is required, configure it with IAM principal tag:

- `SSMSessionRunAs=<linux_username>`

Session Manager uses `SSMSessionRunAs` to determine the OS user for that principal when Run As is enabled.

### Provisioning model for security team

For each operator role, set both tags:

1. `AccessProfile=<profile>`
2. `SSMSessionRunAs=<linux_username>`

Example mapping table:

- `Role: JumpOps-ReadWrite`, `AccessProfile: ops`, `SSMSessionRunAs: jumpops`
- `Role: JumpAudit-ReadOnly`, `AccessProfile: audit`, `SSMSessionRunAs: jumpaudit`

Notes:

- `SSMSessionRunAs` value must match an existing Linux user on the host.
- Linux users are provisioned by this platform's Ansible workflow.
- If you use this repo's `ssm-self-management` allowlist (`session_access_role_mappings`), the inline policy can enforce both principal tags automatically at session start-time.

## Required Session Manager Preferences

Per account and region:

- Session document `SSM-SessionManagerRunShell` must exist
- `inputs.runAsEnabled = true`
- `inputs.cloudWatchLogGroupName = /aws/ssm/jump-host/<env>/<subenv>/<region>`

This repo validates these settings with:

```bash
scripts/preflight_ssm_compliance.sh --region <region> --expected-log-group <name>
```

To self-manage these settings in-account, use:

```bash
scripts/orchestrate.sh <init|plan|apply|configure|check> ... --ssm-self-management
```

## Security Team Validation Checklist

1. IAM role has required SSM/EC2 actions.
2. IAM role has `AccessProfile` tag and `SSMSessionRunAs` tag.
3. ABAC conditions restrict access to tagged jump hosts.
4. Session Manager preferences document is configured for the target region/account.
5. Test `start-session` as an allowed role and a denied role.

## AWS References

- Session Manager Run As behavior and `SSMSessionRunAs`: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html
- Session Manager permissions and examples: https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-examples.html
