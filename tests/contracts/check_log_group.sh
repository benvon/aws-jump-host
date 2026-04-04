#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
orch="$root/scripts/orchestrate.sh"
fail() { echo "contract check failed: $*" >&2; exit 1; }

grep -q 'expected_log_group="/aws/ssm/jump-host/${env_name}/${subenv_name}/${aws_region}"' "$orch" \
  || fail "orchestrate.sh expected_log_group pattern mismatch"

# All example observability stacks must use the same interpolation shape as orchestrate.
while IFS= read -r -d '' f; do
  grep -q 'log_group_name = "/aws/ssm/jump-host/${include.root.locals.env}/${include.root.locals.subenv}/${include.root.locals.aws_region}"' "$f" \
    || fail "observability log_group_name contract broken in $f"
done < <(find "$root/examples/live" -path '*/observability/terragrunt.hcl' -print0)

echo "log group naming contract OK"
