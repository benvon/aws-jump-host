# Example Live Layout

This directory contains reference-only Terragrunt configurations.

## Important

- Replace all placeholder values (`vpc-*`, `subnet-*`, `sg-*`, account IDs, bucket names).
- Prefer copying these examples to a separate environment-input repository.
- Keep secrets and sensitive inputs outside this repository.

## Layout

`<env>/<subenv>/<region>/<stack>` where stack is one of:

- `observability`
- `ssm-self-management` (optional; in-account Session Manager setting management)
- `vpc-endpoints`
- `jump-hosts`

## Suggested Adoption

1. Copy this structure to an external repo.
2. Update `account.hcl`, `region.hcl`, and stack inputs.
3. Run `scripts/orchestrate.sh` from this repository root with `--live-dir` pointing at your live config (the script resolves paths from the repo root). `apply` and `destroy` are interactive unless you pass `--auto-approve`.
