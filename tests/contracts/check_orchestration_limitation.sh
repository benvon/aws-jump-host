#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "contract check failed: $*" >&2; exit 1; }

phrase="plan and configure require an already-applied observability stack, compliant Session Manager preferences, the expected CloudWatch log group, and existing log-transfer outputs. A new account uses apply first."

for file in \
  "$root/scripts/orchestrate.sh" \
  "$root/README.md" \
  "$root/docs/consumer-guide.md"
do
  if ! grep -F -q "$phrase" "$file"; then
    fail "missing first-run limitation in ${file#"$root"/}"
  fi
done

echo "orchestration limitation contract OK"
