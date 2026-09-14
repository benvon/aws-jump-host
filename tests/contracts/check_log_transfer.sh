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
# when JUMP_HOST_ORCHESTRATE is set. Validator path is JUMP_HOST_USERS_VALIDATOR,
# else get_repo_root()/scripts/validate_users_vars.py.
while IFS= read -r -d '' f; do
  grep -q 'JUMP_HOST_ORCHESTRATE' "$f" \
    || fail "log-transfer users_file must honor JUMP_HOST_ORCHESTRATE in $f"
  grep -q 'get_env("JUMP_HOST_USERS_VALIDATOR"' "$f" \
    || fail "log-transfer must resolve the validator from JUMP_HOST_USERS_VALIDATOR in $f"
  grep -q 'validate_users_vars.py' "$f" \
    || fail "log-transfer must fail-closed via validate_users_vars.py in $f"
  grep -q -- '--print-downloader-arns' "$f" \
    || fail "log-transfer must take downloader ARNs from the users validator in $f"
done < <(find "$root/examples/live" -path '*/log-transfer/terragrunt.hcl' -print0)

jh="$root/modules/terraform/jump_hosts/main.tf"
grep -q 'aws_ec2_managed_prefix_list' "$jh" \
  || fail "jump_hosts default SG must look up the regional S3 managed prefix list"
grep -q 'prefix_list_ids' "$jh" \
  || fail "jump_hosts default SG egress must allow the S3 prefix list for gateway-endpoint uploads"
grep -A8 'data "aws_ec2_managed_prefix_list" "s3"' "$jh" | grep -q 'default_sg_hosts' \
  || fail "S3 prefix-list lookup must be gated on module-created default security groups"
grep -A8 'data "aws_ssm_parameter" "al2023_ami_x86_64"' "$jh" | grep -q 'hosts_using_default_ami' \
  || fail "default AMI lookup must be gated on hosts that do not supply ami_id or ami_ssm_parameter_name"

lt="$root/modules/terraform/log_transfer/main.tf"
grep -A8 'instance_upload_object_actions' "$lt" | grep -q 's3:GetObject' \
  || fail "instance role must grant s3:GetObject so operators can pull archives onto the jump host"
grep -A8 'instance_upload_bucket_actions' "$lt" | grep -q '"s3:ListBucket"' \
  || fail "instance role must grant s3:ListBucket so operators can list archives on the jump host"
grep -A12 'variable "retention_days"' "$root/modules/terraform/log_transfer/variables.tf" | grep -q 'var.retention_days <= 730' \
  || fail "log_transfer retention_days must be capped at 730 so ARCHIVE_ACCESS cannot outlive expiration"

docs="$root/docs/consumer-guide.md"
mod_readme="$root/modules/terraform/log_transfer/README.md"
grep -q 'pull an archive back onto the jump host' "$docs" \
  || fail "consumer-guide must document instance-role list/get for host-side download"
grep -q 'pull an archive back onto the jump host' "$mod_readme" \
  || fail "log_transfer README must document instance-role list/get for host-side download"

echo "log-transfer contract OK"
