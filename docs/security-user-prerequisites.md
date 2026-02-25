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

The role should be scoped to jump hosts using instance tags:

- `ssm:resourceTag/JumpHost == "true"`
- `ssm:resourceTag/AccessProfile == ${aws:PrincipalTag/AccessProfile}`

This requires the principal to carry an `AccessProfile` tag (role tag or session tag, per your federation model).

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

## Required Session Manager Service Settings

Per account and region:

- `/ssm/sessionmanager/enableRunAs = true`
- `/ssm/sessionmanager/enableCloudWatchLogging = true`
- `/ssm/sessionmanager/cloudWatchLogGroupName = /aws/ssm/jump-host/<env>/<subenv>/<region>`

This repo validates these settings with:

```bash
scripts/preflight_ssm_compliance.sh --region <region> --expected-log-group <name>
```

## Security Team Validation Checklist

1. IAM role has required SSM/EC2 actions.
2. IAM role has `AccessProfile` tag and `SSMSessionRunAs` tag.
3. ABAC conditions restrict access to tagged jump hosts.
4. Session Manager service settings are configured for the target region/account.
5. Test `start-session` as an allowed role and a denied role.

## AWS References

- Session Manager Run As behavior and `SSMSessionRunAs`: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html
- Session Manager permissions and examples: https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-examples.html
