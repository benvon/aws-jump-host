# Consumer Guide

## Intended Consumption Model

Use this repository as shared orchestration code while storing environment-specific values and secrets in an external repository.

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
3. `./scripts/orchestrate.sh apply --live-dir ...`

For host configuration changes without Terraform execution (for example user add/remove only):

- `./scripts/orchestrate.sh configure --live-dir ...`

For teardown:

- `./scripts/orchestrate.sh destroy --live-dir ...`
- Add `--destroy-state` only if removing backend state bucket intentionally.

## User Schema Contract

External vars must follow:

- `username` (required)
- `groups` (required list)
- `sudo_profile` (required: `none|ops|admin`)
- optional `state`, `shell`, `home`

The `user_accounts` role is authoritative for managed users above the UID threshold and disables undeclared users (excluding configured system account allowlist).

## Local and CI Validation

Local:

- `make fmt-check`
- `make lint`
- `make validate`
- `make check`

CI workflows mirror these validations before merge.
