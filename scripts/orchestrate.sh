#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TG_DOWNLOAD_DIR="${TG_DOWNLOAD_DIR:-${REPO_ROOT}/.cache/terragrunt}"

usage() {
  cat <<USAGE
Usage:
  $0 <init|plan|apply|configure|check|destroy> --live-dir <path> --env <env> --subenv <subenv> --region <region> [--users-vars <path>] [--auto-approve] [--ssm-self-management]

  apply and destroy run Terraform interactively by default (no -auto-approve). Pass --auto-approve for
  non-interactive runs (CI/automation).

  --ssm-self-management applies the optional ssm-self-management stack before preflight checks to
  manage required Session Manager preferences in-account.

Examples:
  $0 init --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars ./ansible/vars-schema.example.yml
  $0 plan --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars /path/to/users.yml
  $0 apply --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars /path/to/users.yml --auto-approve
  $0 configure --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars /path/to/users.yml
  $0 apply --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars /path/to/users.yml --ssm-self-management
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

stack_label() {
  local stack_dir="$1"
  if [[ "$stack_dir" == "${REPO_ROOT}/"* ]]; then
    echo "${stack_dir#"${REPO_ROOT}"/}"
  else
    echo "$stack_dir"
  fi
}

log_tg_action() {
  local stack_dir="$1"
  shift
  local label
  label="$(stack_label "$stack_dir")"

  printf "\n==> [%s] terragrunt" "$label"
  printf " %q" "$@"
  printf "\n"
}

run_tg() {
  local stack_dir="$1"
  shift
  log_tg_action "$stack_dir" "$@"
  TG_DOWNLOAD_DIR="$TG_DOWNLOAD_DIR" TG_BACKEND_BOOTSTRAP=true terragrunt --working-dir "$stack_dir" "$@"
}

run_tg_apply() {
  local stack_dir="$1"
  if [[ "$auto_approve" == "true" ]]; then
    run_tg "$stack_dir" apply -auto-approve
  else
    run_tg "$stack_dir" apply
  fi
}

run_tg_destroy() {
  local stack_dir="$1"
  if [[ "$auto_approve" == "true" ]]; then
    run_tg "$stack_dir" destroy -auto-approve
  else
    run_tg "$stack_dir" destroy
  fi
}

log_ansible_action() {
  local playbook="$1"
  local bucket="$2"
  printf "\n==> [ansible/%s] inventory=%s bucket=%s region=%s\n" "$playbook" "$inventory_path" "$bucket" "$aws_region"
}

run_tg_apply_preflight() {
  local stack_dir="$1"
  # Preflight self-management remediation should be non-interactive so plan/apply/configure
  # can run end-to-end without extra prompts.
  run_tg "$stack_dir" init -reconfigure
  TG_DOWNLOAD_DIR="$TG_DOWNLOAD_DIR" TG_BACKEND_BOOTSTRAP=true TG_NO_AUTO_INIT=true terragrunt --working-dir "$stack_dir" apply -auto-approve
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

command_name="$1"
shift

live_dir=""
env_name=""
subenv_name=""
aws_region=""
users_vars=""
auto_approve="false"
ssm_self_management="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live-dir)
      live_dir="$2"
      shift 2
      ;;
    --env)
      env_name="$2"
      shift 2
      ;;
    --subenv)
      subenv_name="$2"
      shift 2
      ;;
    --region)
      aws_region="$2"
      shift 2
      ;;
    --users-vars)
      users_vars="$2"
      shift 2
      ;;
    --auto-approve)
      auto_approve="true"
      shift
      ;;
    --ssm-self-management)
      ssm_self_management="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$live_dir" || -z "$env_name" || -z "$subenv_name" || -z "$aws_region" ]]; then
  usage
  exit 1
fi

region_dir="$live_dir/$env_name/$subenv_name/$aws_region"
observability_dir="$region_dir/observability"
endpoints_dir="$region_dir/vpc-endpoints"
jump_hosts_dir="$region_dir/jump-hosts"
ssm_self_management_dir="$region_dir/ssm-self-management"
inventory_path="${REPO_ROOT}/ansible/inventory/generated-${env_name}-${subenv_name}-${aws_region}.yml"
expected_log_group="/aws/ssm/jump-host/${env_name}/${subenv_name}/${aws_region}"

required_dirs=("$region_dir" "$observability_dir" "$endpoints_dir" "$jump_hosts_dir")
if [[ "$ssm_self_management" == "true" ]]; then
  required_dirs+=("$ssm_self_management_dir")
fi

for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    echo "Required directory not found: $dir" >&2
    exit 1
  fi
done

require_cmd terragrunt
mkdir -p "$TG_DOWNLOAD_DIR"

ensure_target_account_identity() {
  if [[ "${SKIP_ACCOUNT_CHECK:-false}" == "true" ]]; then
    echo "Skipping account identity check (SKIP_ACCOUNT_CHECK=true)."
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "Warning: aws CLI not found; skipping account identity check."
    return 0
  fi

  local account_hcl="${live_dir}/${env_name}/account.hcl"
  if [[ ! -f "$account_hcl" ]]; then
    return 0
  fi

  local expected_account
  expected_account="$(sed -nE 's/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"([0-9]{12})".*/\1/p' "$account_hcl" | head -n1)"
  if [[ -z "$expected_account" ]]; then
    return 0
  fi

  local actual_account
  if ! actual_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    echo "Warning: unable to determine current AWS account from STS; skipping account identity check."
    return 0
  fi

  if [[ "$actual_account" != "$expected_account" ]]; then
    cat >&2 <<EOF
Error: AWS account mismatch for this live configuration.
  expected account_id: ${expected_account}
  active credentials: ${actual_account}

Export credentials/profile for account ${expected_account}, or set SKIP_ACCOUNT_CHECK=true to bypass this guard.
EOF
    exit 1
  fi
}

run_preflight() {
  if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
    echo "Skipping SSM preflight checks (SKIP_PREFLIGHT=true)."
    return 0
  fi

  case "$command_name" in
    plan|apply|configure)
      echo "Applying observability stack before preflight."
      run_tg_apply_preflight "$observability_dir"
      ;;
  esac

  if [[ "$ssm_self_management" == "true" ]]; then
    echo "SSM self-management enabled; applying $ssm_self_management_dir before preflight."
    run_tg_apply_preflight "$ssm_self_management_dir"
  fi

  local cmd=("${SCRIPT_DIR}/preflight_ssm_compliance.sh" --region "$aws_region" --expected-log-group "$expected_log_group")
  "${cmd[@]}"
}

resolve_ssm_transfer_bucket() {
  if [[ -n "${ANSIBLE_AWS_SSM_BUCKET_NAME:-}" ]]; then
    echo "$ANSIBLE_AWS_SSM_BUCKET_NAME"
    return 0
  fi

  local account_hcl="${live_dir}/${env_name}/account.hcl"
  if [[ ! -f "$account_hcl" ]]; then
    echo "Error: could not resolve SSM transfer bucket; missing ${account_hcl}. Set ANSIBLE_AWS_SSM_BUCKET_NAME explicitly." >&2
    exit 1
  fi

  local bucket
  bucket="$(sed -nE 's/^[[:space:]]*ansible_ssm_bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$account_hcl" | head -n1)"
  if [[ -n "$bucket" ]]; then
    echo "$bucket"
    return 0
  fi

  bucket="$(sed -nE 's/^[[:space:]]*state_bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$account_hcl" | head -n1)"
  if [[ -z "$bucket" ]]; then
    echo "Error: could not parse ansible_ssm_bucket or state_bucket from ${account_hcl}. Set ANSIBLE_AWS_SSM_BUCKET_NAME explicitly." >&2
    exit 1
  fi

  echo "$bucket"
}

check_ssm_transfer_bucket_access() {
  local bucket="$1"
  if ! command -v aws >/dev/null 2>&1; then
    echo "Warning: aws CLI not found; skipping SSM transfer bucket access check for ${bucket}."
    return 0
  fi

  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<EOF
Error: unable to access SSM transfer bucket '${bucket}' with current AWS credentials.

Ansible's amazon.aws.aws_ssm connection requires controller access to this bucket:
  - s3:ListBucket on arn:aws:s3:::${bucket}
  - s3:GetObject,s3:PutObject,s3:DeleteObject on arn:aws:s3:::${bucket}/*

Set a different bucket with ANSIBLE_AWS_SSM_BUCKET_NAME (or account.hcl local ansible_ssm_bucket),
or grant the current role access to this bucket.
EOF
  exit 1
}

ensure_ansible_collections() {
  local ssm_plugin_path="${REPO_ROOT}/ansible/collections/ansible_collections/amazon/aws/plugins/connection/aws_ssm.py"
  if [[ -f "$ssm_plugin_path" ]]; then
    return 0
  fi

  require_cmd ansible-galaxy
  echo "Installing Ansible collections from ansible/requirements.yml ..."
  ansible-galaxy collection install \
    -r "${REPO_ROOT}/ansible/requirements.yml" \
    -p "${REPO_ROOT}/ansible/collections"
}

run_ansible() {
  local playbook="$1"
  local check_mode="${2:-false}"
  local omit_users_vars="${3:-false}"
  local extra=()
  local host_count
  local ssm_transfer_bucket

  ensure_ansible_collections
  require_cmd ansible-playbook
  require_cmd jq

  "${SCRIPT_DIR}/render_inventory.sh" \
    --terragrunt-dir "$jump_hosts_dir" \
    --output "$inventory_path"

  host_count="$(jq -r '.all.children.jump_hosts.hosts | length' "$inventory_path")"
  if [[ "$host_count" -eq 0 ]]; then
    printf "\n==> [ansible/%s] WARNING: inventory has 0 jump hosts — the play is skipped (no roles or tasks run, including session_comfort).\n" "$playbook" >&2
    printf "    Fix: ensure Terraform apply created instances and terragrunt output 'hosts' is non-empty for %s\n" "$jump_hosts_dir" >&2
  fi
  if [[ "$host_count" -gt 0 ]]; then
    ssm_transfer_bucket="$(resolve_ssm_transfer_bucket)"
    check_ssm_transfer_bucket_access "$ssm_transfer_bucket"
    log_ansible_action "$playbook" "$ssm_transfer_bucket"

    "${SCRIPT_DIR}/render_inventory.sh" \
      --terragrunt-dir "$jump_hosts_dir" \
      --output "$inventory_path" \
      --connection "amazon.aws.aws_ssm" \
      --ssm-region "$aws_region" \
      --ssm-bucket "$ssm_transfer_bucket" \
      --s3-addressing-style "virtual"

    extra+=(--extra-vars "ansible_aws_ssm_bucket_name=${ssm_transfer_bucket}")
    # Avoid cross-region redirect edge cases in the SSM plugin's S3 transfers.
    extra+=(--extra-vars "ansible_aws_ssm_s3_addressing_style=virtual")
  else
    printf "\n==> [ansible/%s] inventory=%s hosts=0 (skipping SSM bucket checks)\n" "$playbook" "$inventory_path"
  fi

  if [[ -n "$users_vars" && "$omit_users_vars" != "true" ]]; then
    extra+=(--extra-vars "@$users_vars")
  fi

  if [[ -n "$env_name" ]]; then
    extra+=(--extra-vars "jump_host_environment=${env_name}")
  fi

  if [[ "$check_mode" == "true" ]]; then
    extra+=(--check)
  fi

  # Resolve roles_path (ansible/roles) from repo ansible.cfg even if cwd is not REPO_ROOT.
  ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg" \
  AWS_REGION="$aws_region" \
  OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES \
  ansible-playbook \
    -i "$inventory_path" \
    "${REPO_ROOT}/ansible/playbooks/${playbook}" \
    "${extra[@]}"
}

case "$command_name" in
  init)
    ensure_target_account_identity
    run_tg "$observability_dir" init
    if [[ "$ssm_self_management" == "true" ]]; then
      run_tg "$ssm_self_management_dir" init
    fi
    run_tg "$endpoints_dir" init
    run_tg "$jump_hosts_dir" init
    ;;

  check)
    ensure_target_account_identity
    require_cmd terraform
    require_cmd terragrunt
    require_cmd ansible-lint
    require_cmd yamllint
    require_cmd shellcheck
    require_cmd tflint
    require_cmd tfsec
    require_cmd checkov

    terraform fmt -check -recursive modules examples
    terragrunt hcl format --check --working-dir terragrunt --exclude-dir .terragrunt-cache --exclude-dir .terraform
    terragrunt hcl format --check --working-dir examples/live --exclude-dir .terragrunt-cache --exclude-dir .terraform
    ansible-lint ansible/playbooks ansible/roles ansible/group_vars ansible/requirements.yml ansible/vars-schema.example.yml
    yamllint ansible/playbooks ansible/roles ansible/group_vars ansible/requirements.yml ansible/vars-schema.example.yml
    shellcheck scripts/*.sh
    tflint --init
    tflint --recursive modules/terraform
    tfsec modules/terraform
    checkov -d modules/terraform

    run_preflight
    ;;

  plan)
    ensure_target_account_identity
    run_preflight
    run_tg "$observability_dir" plan
    run_tg "$endpoints_dir" plan
    run_tg "$jump_hosts_dir" plan

    run_ansible "jump_hosts.yml" "true"
    ;;

  apply)
    ensure_target_account_identity
    run_preflight
    run_tg_apply "$observability_dir"
    run_tg_apply "$endpoints_dir"
    run_tg_apply "$jump_hosts_dir"

    run_ansible "jump_hosts.yml"
    ;;

  configure)
    ensure_target_account_identity
    run_preflight
    run_ansible "jump_hosts.yml"
    ;;

  destroy)
    ensure_target_account_identity
    if [[ -n "$users_vars" ]]; then
      run_ansible "decommission.yml" "false" "true"
    else
      echo "Skipping Ansible decommission hooks (no --users-vars provided)."
    fi

    run_tg_destroy "$jump_hosts_dir"
    run_tg_destroy "$endpoints_dir"
    run_tg_destroy "$observability_dir"
    ;;

  *)
    echo "Unsupported command: $command_name" >&2
    usage
    exit 1
    ;;
esac
