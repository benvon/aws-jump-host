#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "contract check failed: $*" >&2; exit 1; }

# Fresh log-transfer stacks must mock jump-hosts outputs during init as well as
# validate/plan: orchestrate and the optional AWS plan workflow run
# `terragrunt init` before jump-hosts has been applied.
while IFS= read -r -d '' f; do
  grep -Eq 'mock_outputs_allowed_terraform_commands[[:space:]]*=[[:space:]]*\[[^]]*init[^]]*\]' "$f" \
    || fail "log-transfer mock allowlist must include init in $f"
done < <(find "$root/examples/live" -path '*/log-transfer/terragrunt.hcl' -print0)

# Orchestrate without --users-vars uses users: [] in Ansible. The stack must not
# independently fall back to JUMP_HOST_USERS_VARS or ancestor ansible/users.yaml
# when JUMP_HOST_ORCHESTRATE is set.
while IFS= read -r -d '' f; do
  grep -q 'JUMP_HOST_ORCHESTRATE' "$f" \
    || fail "log-transfer users_file must honor JUMP_HOST_ORCHESTRATE in $f"
done < <(find "$root/examples/live" -path '*/log-transfer/terragrunt.hcl' -print0)

jh="$root/modules/terraform/jump_hosts/main.tf"
grep -q 'aws_ec2_managed_prefix_list' "$jh" \
  || fail "jump_hosts default SG must look up the regional S3 managed prefix list"
grep -q 'prefix_list_ids' "$jh" \
  || fail "jump_hosts default SG egress must allow the S3 prefix list for gateway-endpoint uploads"

echo "log-transfer contract OK"
