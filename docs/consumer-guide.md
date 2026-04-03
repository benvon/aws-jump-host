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
- `env.hcl`, `subenv.hcl`, `region.hcl`, and `account.hcl`
- Encrypted user vars file compatible with `ansible/vars-schema.example.yml`

Then reference module and root paths from this repository.

## Minimum Inputs Per Region

- `vpc_id`
- endpoint subnet IDs and SG IDs for interface endpoints
- host definitions (`hosts` map) with per-host subnet and access metadata
- account ID and assume-role name
- state bucket name

## Operator Workflow

From this repository root:

1. `./scripts/orchestrate.sh init --live-dir <external-live-dir> --env <env> --subenv <subenv> --region <region> --users-vars <users-file>`
2. `./scripts/orchestrate.sh plan --live-dir ...`
3. `./scripts/orchestrate.sh apply --live-dir ...` (Terraform prompts for confirmation on each stack unless you pass `--auto-approve`)

For host configuration changes without Terraform execution (for example user add/remove only):

- `./scripts/orchestrate.sh configure --live-dir ...`

For teardown:

- `./scripts/orchestrate.sh destroy --live-dir ...` (interactive by default; use `--auto-approve` only for automation)
- Add `--destroy-state` only if removing backend state bucket intentionally.

Non-interactive CI or scripted applies should append `--auto-approve` to both `apply` and `destroy`. The Makefile provides `apply-example-auto` and `destroy-example-auto` for the bundled examples.

## User Schema Contract

External vars must follow:

- `username` (required)
- `groups` (required list)
- `sudo_profile` (required: `none|ops|admin`)
- optional `state`, `shell`, `home`

The `user_accounts` role is authoritative for managed users above the UID threshold and disables undeclared users (excluding configured system account allowlist).

To customize the `ops` sudo allowlist, set `user_accounts_ops_sudo_commands` in group vars or extra-vars (this repository’s `ansible/group_vars/all.yml` is the default). If you previously used `ops_sudo_commands` in an external inputs repo, rename that key to match the role variable.

## Local and CI Validation

Local:

- `make fmt-check`
- `make lint`
- `make validate`
- `make check`

CI workflows mirror these validations before merge.
