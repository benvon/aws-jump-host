#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --terragrunt-dir <path> --output <path> [--group <name>] [--connection <ansible-connection>] [--ssm-region <region>] [--ssm-bucket <bucket>] [--s3-addressing-style <style>]

Renders an Ansible inventory from terragrunt output "hosts".
USAGE
}

terragrunt_dir=""
output_path=""
group_name="jump_hosts"
connection=""
ssm_region=""
ssm_bucket=""
s3_addressing_style=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terragrunt-dir)
      terragrunt_dir="$2"
      shift 2
      ;;
    --output)
      output_path="$2"
      shift 2
      ;;
    --group)
      group_name="$2"
      shift 2
      ;;
    --connection)
      connection="$2"
      shift 2
      ;;
    --ssm-region)
      ssm_region="$2"
      shift 2
      ;;
    --ssm-bucket)
      ssm_bucket="$2"
      shift 2
      ;;
    --s3-addressing-style)
      s3_addressing_style="$2"
      shift 2
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

if [[ -z "$terragrunt_dir" || -z "$output_path" ]]; then
  usage
  exit 1
fi

if ! command -v terragrunt >/dev/null 2>&1; then
  echo "terragrunt is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"

# Fall back to an empty hosts map when there is no state yet or outputs are not populated, so `plan` can run
# Ansible in check mode with zero hosts. Avoid matching English stderr from Terragrunt (locale/version drift).
# If state has resources but `hosts` output is unreadable, treat that as an error.
terragrunt_err_file="$(mktemp)"
state_list_file="$(mktemp)"
if hosts_json="$(terragrunt --working-dir "$terragrunt_dir" output -json hosts 2>"$terragrunt_err_file")"; then
  # Terragrunt often returns the raw map; terraform-style JSON wraps {value,type,sensitive}; null → {}.
  hosts_json="$(printf '%s\n' "$hosts_json" | jq -c '.value // . // {}')"
elif all_json="$(terragrunt --working-dir "$terragrunt_dir" output -json 2>"$terragrunt_err_file")"; then
  hosts_json="$(echo "$all_json" | jq -c '.hosts.value? // {}')"
elif terragrunt --working-dir "$terragrunt_dir" state list >"$state_list_file" 2>>"$terragrunt_err_file" \
  && [[ ! -s "$state_list_file" ]]; then
  echo "Warning: Terraform state is empty or outputs missing in ${terragrunt_dir}; using empty hosts inventory." >&2
  hosts_json="{}"
elif ! terragrunt --working-dir "$terragrunt_dir" state list >/dev/null 2>>"$terragrunt_err_file"; then
  echo "Warning: Terraform state not available in ${terragrunt_dir}; using empty hosts inventory." >&2
  hosts_json="{}"
else
  echo "Error: state has resources but terragrunt outputs (hosts) could not be read:" >&2
  cat "$terragrunt_err_file" >&2
  rm -f "$terragrunt_err_file" "$state_list_file"
  exit 1
fi
rm -f "$terragrunt_err_file" "$state_list_file"

jq -n \
  --argjson hosts "$hosts_json" \
  --arg group "$group_name" \
  --arg connection "$connection" \
  --arg ssm_region "$ssm_region" \
  --arg ssm_bucket "$ssm_bucket" \
  --arg s3_addressing_style "$s3_addressing_style" \
  '
  def maybe_var(k; v): if (v | length) > 0 then { (k): v } else {} end;
  {
    all: {
      children: {
        ($group): (
          {
            hosts: (
              reduce ($hosts | to_entries[]) as $h ({};
                .[$h.value.instance_id] = {
                  ansible_host: $h.value.instance_id,
                  host_name: $h.key,
                  private_ip: $h.value.private_ip,
                  access_profile: $h.value.access_profile
                }
              )
            )
          } +
          (
            (
              maybe_var("ansible_connection"; $connection) +
              maybe_var("ansible_aws_ssm_region"; $ssm_region) +
              maybe_var("ansible_aws_ssm_bucket_name"; $ssm_bucket) +
              maybe_var("ansible_aws_ssm_s3_addressing_style"; $s3_addressing_style)
            ) as $vars
            | if ($vars | length) > 0 then { vars: $vars } else {} end
          )
        )
      }
    }
  }
  ' > "$output_path"

echo "Wrote inventory: $output_path"
