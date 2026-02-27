#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --terragrunt-dir <path> --output <path> [--group <name>]

Renders an Ansible inventory from terragrunt output "hosts".
USAGE
}

terragrunt_dir=""
output_path=""
group_name="jump_hosts"

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

# When no state exists (e.g. after init but before apply), terragrunt output fails.
# Use empty object so plan can complete; Ansible will run with zero hosts.
terragrunt_err_file="$(mktemp)"
if ! hosts_json="$(terragrunt --working-dir "$terragrunt_dir" output -json hosts 2>"$terragrunt_err_file")"; then
  if grep -qiE 'no outputs found|no state file|state does not exist' "$terragrunt_err_file"; then
    # Expected case: no state / no outputs yet. Proceed with an empty inventory.
    echo "Warning: terragrunt reported no state/outputs; proceeding with empty hosts inventory." >&2
    hosts_json="{}"
  else
    echo "Error: failed to retrieve terragrunt hosts output:" >&2
    cat "$terragrunt_err_file" >&2
    rm -f "$terragrunt_err_file"
    exit 1
  fi
fi
rm -f "$terragrunt_err_file"

jq -n \
  --argjson hosts "$hosts_json" \
  --arg group "$group_name" \
  '
  {
    all: {
      children: {
        ($group): {
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
        }
      }
    }
  }
  ' > "$output_path"

echo "Wrote inventory: $output_path"
