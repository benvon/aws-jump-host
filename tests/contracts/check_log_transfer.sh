#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "contract check failed: $*" >&2; exit 1; }

# log-transfer no longer attaches IAM to the jump-host instance role, so the
# stack must not depend on jump-hosts outputs.
while IFS= read -r -d '' f; do
  grep -q 'instance_role_' "$f" \
    && fail "log-transfer must not pass instance_role_* in $f"
  grep -q 'dependency "jump_hosts"' "$f" \
    && fail "log-transfer must not depend on jump-hosts in $f"
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
grep -q 'instance_role' "$lt" \
  && fail "log_transfer must not grant the jump-host instance role any S3 access"
grep -q 'aws_iam_role_policy' "$lt" \
  && fail "log_transfer must not attach an inline policy to the jump-host instance role"
grep -A20 'downloader_role_arns' "$lt" | grep -q 's3:PutObject' \
  || fail "operator role ARNs must be allowed to upload (s3:PutObject) via the bucket policy"
grep -A12 'variable "retention_days"' "$root/modules/terraform/log_transfer/variables.tf" | grep -q 'var.retention_days <= 730' \
  || fail "log_transfer retention_days must be capped at 730 so ARCHIVE_ACCESS cannot outlive expiration"

helper="$root/ansible/roles/session_comfort/files/log-transfer"
grep -q 'env -u AWS_PROFILE' "$helper" \
  && fail "log-transfer helper must keep the operator AWS_PROFILE"
grep -q 'AWS_EC2_METADATA_DISABLED=true' "$helper" \
  || fail "log-transfer helper must disable IMDS so the instance role cannot be used"

docs="$root/docs/consumer-guide.md"
mod_readme="$root/modules/terraform/log_transfer/README.md"
readme="$root/README.md"
arch="$root/docs/architecture.md"
grep -q 'pull an archive back onto the jump host' "$docs" \
  && fail "consumer-guide must not document instance-role host-side download"
grep -q 'operator credentials' "$docs" \
  || fail "consumer-guide must document that log-transfer uses operator credentials"
grep -q 'intentionally without significant' "$docs" \
  || fail "consumer-guide must state the instance role is intentionally without significant privileges"
grep -q 'pull an archive back onto the jump host' "$mod_readme" \
  && fail "log_transfer README must not document instance-role host-side download"
grep -q 'intentionally without significant IAM role privileges' "$readme" \
  || fail "README must state the jump-host instance is intentionally without significant IAM role privileges"
grep -q 'SSM-only by design' "$arch" \
  || fail "architecture.md must state jump-host instance IAM is SSM-only by design"

echo "log-transfer contract OK"
