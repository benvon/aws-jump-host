#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "contract check failed: $*" >&2; exit 1; }

# Deprecated YAML key (replaced by user_accounts_ops_sudo_commands); allow prose in docs without a defining colon.
if grep -RIn --include='*.yml' --include='*.yaml' -e '^[[:space:]]*ops_sudo_commands[[:space:]]*:' \
  "$root/ansible/playbooks" "$root/ansible/roles" "$root/ansible/group_vars" 2>/dev/null | grep -q .; then
  fail "ops_sudo_commands: still used under ansible playbooks/roles/group_vars; use user_accounts_ops_sudo_commands"
fi

echo "deprecated vars contract OK"
