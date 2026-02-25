#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TG_DOWNLOAD_DIR="${TG_DOWNLOAD_DIR:-${REPO_ROOT}/.cache/terragrunt}"

usage() {
  cat <<USAGE
Usage:
  $0 <init|plan|apply|check|destroy> --live-dir <path> --env <env> --subenv <subenv> --region <region> [--users-vars <path>] [--expected-run-as-user <user>] [--destroy-state]

Examples:
  $0 init --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars ./ansible/vars-schema.example.yml
  $0 plan --live-dir ./examples/live --env dev --subenv east --region us-east-1 --users-vars /path/to/users.yml
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run_tg() {
  local stack_dir="$1"
  shift
  TG_DOWNLOAD_DIR="$TG_DOWNLOAD_DIR" terragrunt --working-dir "$stack_dir" "$@"
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
expected_run_as_user=""
destroy_state="false"

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
    --expected-run-as-user)
      expected_run_as_user="$2"
      shift 2
      ;;
    --destroy-state)
      destroy_state="true"
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
bootstrap_dir="$region_dir/bootstrap-state"
observability_dir="$region_dir/observability"
endpoints_dir="$region_dir/vpc-endpoints"
jump_hosts_dir="$region_dir/jump-hosts"
inventory_path="ansible/inventory/generated-${env_name}-${subenv_name}-${aws_region}.yml"
expected_log_group="/aws/ssm/jump-host/${env_name}/${subenv_name}/${aws_region}"

for dir in "$region_dir" "$bootstrap_dir" "$observability_dir" "$endpoints_dir" "$jump_hosts_dir"; do
  if [[ ! -d "$dir" ]]; then
    echo "Required directory not found: $dir" >&2
    exit 1
  fi
done

require_cmd terragrunt
mkdir -p "$TG_DOWNLOAD_DIR"

run_preflight() {
  if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
    echo "Skipping SSM preflight checks (SKIP_PREFLIGHT=true)."
    return 0
  fi

  local cmd=(scripts/preflight_ssm_compliance.sh --region "$aws_region" --expected-log-group "$expected_log_group")
  if [[ -n "$expected_run_as_user" ]]; then
    cmd+=(--expected-run-as-user "$expected_run_as_user")
  fi
  "${cmd[@]}"
}

run_ansible() {
  local playbook="$1"
  local check_mode="${2:-false}"
  local omit_users_vars="${3:-false}"
  local extra=()

  require_cmd ansible-playbook
  require_cmd jq

  scripts/render_inventory.sh --terragrunt-dir "$jump_hosts_dir" --output "$inventory_path"

  if [[ -n "$users_vars" && "$omit_users_vars" != "true" ]]; then
    extra+=(--extra-vars "@$users_vars")
  fi

  if [[ "$check_mode" == "true" ]]; then
    extra+=(--check)
  fi

  AWS_REGION="$aws_region" ansible-playbook \
    -i "$inventory_path" \
    "ansible/playbooks/${playbook}" \
    "${extra[@]}"
}

case "$command_name" in
  init)
    run_tg "$bootstrap_dir" init
    run_tg "$observability_dir" init
    run_tg "$endpoints_dir" init
    run_tg "$jump_hosts_dir" init
    ;;

  check)
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
    run_preflight
    run_tg "$bootstrap_dir" plan
    run_tg "$observability_dir" plan
    run_tg "$endpoints_dir" plan
    run_tg "$jump_hosts_dir" plan

    run_ansible "jump_hosts.yml" "true"
    ;;

  apply)
    run_preflight
    run_tg "$bootstrap_dir" apply -auto-approve
    run_tg "$observability_dir" apply -auto-approve
    run_tg "$endpoints_dir" apply -auto-approve
    run_tg "$jump_hosts_dir" apply -auto-approve

    run_ansible "jump_hosts.yml"
    ;;

  destroy)
    if [[ -n "$users_vars" ]]; then
      run_ansible "decommission.yml" "false" "true"
    else
      echo "Skipping Ansible decommission hooks (no --users-vars provided)."
    fi

    run_tg "$jump_hosts_dir" destroy -auto-approve
    run_tg "$endpoints_dir" destroy -auto-approve
    run_tg "$observability_dir" destroy -auto-approve

    if [[ "$destroy_state" == "true" ]]; then
      run_tg "$bootstrap_dir" destroy -auto-approve
    else
      echo "Skipping bootstrap-state destroy. Use --destroy-state to remove remote state bucket."
    fi
    ;;

  *)
    echo "Unsupported command: $command_name" >&2
    usage
    exit 1
    ;;
esac
