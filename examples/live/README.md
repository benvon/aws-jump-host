# Example Live Layout

This directory contains reference-only Terragrunt configurations.

## Important

- Replace all placeholder values (`vpc-*`, `subnet-*`, `sg-*`, account IDs, bucket names).
- Prefer copying these examples to a separate environment-input repository.
- Keep secrets and sensitive inputs outside this repository.

## Layout

`<env>/<subenv>/<region>/<stack>` where stack is one of:

- `bootstrap-state`
- `observability`
- `vpc-endpoints`
- `jump-hosts`

## Suggested Adoption

1. Copy this structure to an external repo.
2. Update `account.hcl`, `region.hcl`, and stack inputs.
3. Run `scripts/orchestrate.sh` from this repo with `--live-dir` pointing to external config.
