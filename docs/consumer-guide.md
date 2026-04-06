# Consumer Guide

## Intended Consumption Model

Use this repository as shared orchestration code while storing environment-specific values and secrets in an external repository.

For AWS Security/IAM and user provisioning prerequisites, use:

- `docs/security-user-prerequisites.md`

For cost planning and estimation framework, use:

- `docs/cost-estimation.md`

## External Inputs Repository Pattern

Create a separate repo with:

- `live/<env>/<subenv>/<region>/<stack>/terragrunt.hcl`
- optional stack: `ssm-self-management` (for in-account Session Manager preference management)
- `env.hcl`, `subenv.hcl`, `region.hcl`, and `account.hcl`
- Encrypted user vars file compatible with `ansible/vars-schema.example.yml`

Then reference module and root paths from this repository.

## Global AWS tags (cascade)

`terragrunt/root.hcl` builds `common_tags` and applies them in two ways:

1. **Provider `default_tags`** (generated `provider_generated.tf`) — taggable AWS resources created in these stacks receive these tags even when a module does not set `tags`.
2. **Module inputs** — stacks pass `include.root.locals.common_tags` (or merge with it) so modules that explicitly merge tags keep the same baseline keys.

Built-in keys today: `Project`, `Environment`, `SubEnvironment`, `Region`, `ManagedBy`.

To add your own tags once and have them flow everywhere, define optional `extra_tags` maps in your live hierarchy files (same merge as `common_tags`; duplicate keys are overridden by the more specific file):

| File           | Typical use                                      |
|----------------|--------------------------------------------------|
| `account.hcl`  | Account-wide tags (`CostCenter`, `Owner`, …)     |
| `env.hcl`      | Environment-wide tags (`DataClassification`, …) |
| `subenv.hcl`   | Sub-environment or segment tags                  |

Example in `account.hcl`:

```hcl
locals {
  account_id       = "123456789012"
  assume_role_name = "OrganizationAccountAccessRole"
  state_bucket     = "my-org-jump-host-state"
  # Optional: bucket used by Ansible amazon.aws.aws_ssm file transfer.
  # If omitted, orchestrate.sh falls back to state_bucket.
  ansible_ssm_bucket = "my-org-jump-host-ansible-ssm"
  extra_tags = {
    CostCenter = "platform-engineering"
  }
}
```

Omit `extra_tags` in a file if you do not need that layer.

## Minimum Inputs Per Region

- `vpc_id`
- endpoint subnet IDs for interface endpoints
- optional endpoint SG IDs (if omitted, module-managed endpoint SGs are created)
- optional additional interface endpoint services override (defaults already include EKS management baseline)
- optional S3 gateway endpoint route table IDs (if omitted, inferred from endpoint subnets)
- host definitions (`hosts` map) with per-host subnet and access metadata
- account ID and assume-role name
- state bucket name
- optional `ansible_ssm_bucket` (otherwise `state_bucket` is used for Ansible SSM transfer)

## Operator Workflow

From this repository root:

1. `./scripts/orchestrate.sh init --live-dir <external-live-dir> --env <env> --subenv <subenv> --region <region> --users-vars <users-file>`
2. `./scripts/orchestrate.sh plan --live-dir ...`
3. `./scripts/orchestrate.sh apply --live-dir ...` (Terraform prompts for confirmation on each stack unless you pass `--auto-approve`)

If Session Manager preferences are not centrally managed yet, append `--ssm-self-management` to `init|plan|apply|configure|check` so preflight can apply the optional `ssm-self-management` stack before validation.

When enabled, `ssm-self-management` configures both:

- Session Manager preferences document (`SSM-SessionManagerRunShell`)
- Default Host Management role setting (`/ssm/managed-instance/default-ec2-instance-management-role`)

If `enable_run_as=true`, set `run_as_default_user` (for Amazon Linux, typically `ec2-user`) unless your organization maps users via IAM principal tag `SSMSessionRunAs`.

When `ssm-self-management` is enabled, this repo can also self-manage an SSM session role allowlist by reading `live/ansible/users.yaml` and attaching inline IAM policies to declared role ARNs.

For Ansible over SSM, the controller role needs S3 access to the transfer bucket (`ansible_ssm_bucket`, or `state_bucket` fallback):

- `s3:ListBucket` on `arn:aws:s3:::<bucket>`
- `s3:GetObject,s3:PutObject,s3:DeleteObject` on `arn:aws:s3:::<bucket>/*`

You can override bucket selection at runtime with `ANSIBLE_AWS_SSM_BUCKET_NAME=<bucket>`.

By default, VPC endpoints include this private-EKS management baseline:

- `eks`
- `sts`
- `ecr.api`
- `ecr.dkr`
- `ec2`
- `elasticloadbalancing`
- `autoscaling`

To override defaults for a region, set `additional_interface_endpoint_services` in `region.hcl`.

For host configuration changes without Terraform execution (for example user add/remove only):

- `./scripts/orchestrate.sh configure --live-dir ...`

For teardown:

- `./scripts/orchestrate.sh destroy --live-dir ...` (interactive by default; use `--auto-approve` only for automation)

Non-interactive CI or scripted applies should append `--auto-approve` to both `apply` and `destroy`. The Makefile provides `apply-example-auto` and `destroy-example-auto` for the bundled examples.

## User Schema Contract

External vars must follow:

- `username` (required)
- `groups` (required list)
- `sudo_profile` (required: `none|ops|admin`)
- optional `state`, `shell`, `home`
- optional `access_profile` (required when `iam_role_arns` is set)
- optional `iam_role_arns` (list of IAM role ARNs to allowlist for SSM session start)
- optional `ssm_session_linux_user` (defaults to `username`; used for `SSMSessionRunAs` mapping)

If `iam_role_arns` are provided, the `ssm-self-management` stack maps each role to that user's `access_profile` and Linux user and attaches an inline IAM policy that restricts Session Manager access to:

- jump hosts tagged `JumpHost=true`
- hosts whose `AccessProfile` tag matches the mapped profile
- principals tagged with matching `AccessProfile` and `SSMSessionRunAs` values

For IAM Identity Center roles (`AWSReservedSSO_*`), IAM role mutation is blocked by AWS. In that case set `session_access_attach_role_policies=false` in `ssm-self-management`; use the generated policy document output and apply equivalent permissions in the Identity Center Permission Set.

To export the generated per-role policy JSON for handoff:

```bash
./scripts/export_ssm_allowlist_policy.sh \
  --terragrunt-dir live/<env>/<subenv>/<region>/ssm-self-management \
  --role-arn <iam-role-arn> \
  --output /tmp/ssm-allowlist-policy.json
```

The `user_accounts` role is authoritative for managed users above the UID threshold and disables undeclared users (excluding configured system account allowlist).

To customize the `ops` sudo allowlist, set `user_accounts_ops_sudo_commands` in group vars or extra-vars (this repository’s `ansible/group_vars/all.yml` is the default). If you previously used `ops_sudo_commands` in an external inputs repo, rename that key to match the role variable.

## Local and CI Validation

Local:

- `make fmt-check`
- `make lint`
- `make validate`
- `make check`

CI workflows mirror these validations before merge.
