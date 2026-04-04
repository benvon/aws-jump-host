#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
versions="$root/.tool-versions"
action="$root/.github/actions/ci-setup/action.yml"
fail() { echo "contract check failed: $*" >&2; exit 1; }

[[ -f "$versions" ]] || fail "missing .tool-versions"
[[ -f "$action" ]] || fail "missing ci-setup action"

tf_mise="$(awk '/^terraform[[:space:]]/ {print $2; exit}' "$versions")"
tg_mise="$(awk '/^terragrunt[[:space:]]/ {print $2; exit}' "$versions")"
[[ -n "$tf_mise" ]] || fail "terraform pin not found in .tool-versions"
[[ -n "$tg_mise" ]] || fail "terragrunt pin not found in .tool-versions"

tf_action="$(awk -F': ' '/terraform_version:/ {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$action")"
tg_action="$(awk -F': ' '/terragrunt-version:/ {gsub(/["[:space:]]/, "", $2); print $2; exit}' "$action")"
[[ -n "$tf_action" ]] || fail "terraform_version not found in ci-setup"
[[ -n "$tg_action" ]] || fail "terragrunt-version not found in ci-setup"

[[ "$tf_mise" == "$tf_action" ]] || fail "Terraform pin mismatch: .tool-versions=$tf_mise ci-setup=$tf_action"
[[ "$tg_mise" == "$tg_action" ]] || fail "Terragrunt pin mismatch: .tool-versions=$tg_mise ci-setup=$tg_action"

echo "tool pin contract OK (terraform=$tf_mise terragrunt=$tg_mise)"
