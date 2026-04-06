#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --terragrunt-dir <path> --role-arn <iam-role-arn> [--output <file>]

Exports the generated SSM allowlist IAM policy document JSON for a specific role ARN
from the ssm-self-management terragrunt stack output.

Examples:
  $0 \\
    --terragrunt-dir live/stage/west/us-west-2/ssm-self-management \\
    --role-arn arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/us-east-2/AWSReservedSSO_example

  $0 \\
    --terragrunt-dir live/stage/west/us-west-2/ssm-self-management \\
    --role-arn arn:aws:iam::123456789012:role/MyOperatorRole \\
    --output /tmp/ssm-allowlist-policy.json
USAGE
}

terragrunt_dir=""
role_arn=""
output_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terragrunt-dir)
      terragrunt_dir="$2"
      shift 2
      ;;
    --role-arn)
      role_arn="$2"
      shift 2
      ;;
    --output)
      output_path="$2"
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

if [[ -z "$terragrunt_dir" || -z "$role_arn" ]]; then
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

terragrunt_err_file="$(mktemp)"
if ! allowlist_json="$(terragrunt --working-dir "$terragrunt_dir" output -json session_access_allowlist 2>"$terragrunt_err_file")"; then
  echo "Error: failed to read output 'session_access_allowlist' from $terragrunt_dir" >&2
  cat "$terragrunt_err_file" >&2
  rm -f "$terragrunt_err_file"
  exit 1
fi
rm -f "$terragrunt_err_file"

if ! echo "$allowlist_json" | jq -e '.policy_documents_by_role_arn' >/dev/null 2>&1; then
  echo "Error: output does not include policy_documents_by_role_arn." >&2
  echo "Apply the latest ssm-self-management stack first, then retry." >&2
  exit 1
fi

if ! echo "$allowlist_json" | jq -e --arg role_arn "$role_arn" '.policy_documents_by_role_arn[$role_arn]' >/dev/null 2>&1; then
  echo "Error: no generated policy document found for role ARN: $role_arn" >&2
  echo "Known role ARNs from this output:" >&2
  echo "$allowlist_json" | jq -r '.mappings[].role_arn' >&2
  exit 1
fi

policy_json="$(echo "$allowlist_json" | jq --arg role_arn "$role_arn" '.policy_documents_by_role_arn[$role_arn]')"

if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  echo "$policy_json" | jq '.' > "$output_path"
  echo "Wrote policy JSON: $output_path"
else
  echo "$policy_json" | jq '.'
fi
