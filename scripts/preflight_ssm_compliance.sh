#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --region <aws-region> --expected-log-group <name> [--document-name <name>]

Validates externally managed SSM Session Manager account-level preferences required by this solution.
These settings may be centrally managed, or managed in-account via the optional
ssm-self-management stack.

  --document-name   Name of the Session Manager preferences document (default: SSM-SessionManagerRunShell).
USAGE
}

region=""
expected_log_group=""
document_name="SSM-SessionManagerRunShell"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      region="$2"
      shift 2
      ;;
    --expected-log-group)
      expected_log_group="$2"
      shift 2
      ;;
    --document-name)
      [[ -n "${2:-}" ]] || { echo "Error: --document-name requires a value" >&2; usage; exit 1; }
      document_name="$2"
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

if [[ -z "$region" || -z "$expected_log_group" ]]; then
  usage
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

session_doc_content() {
  aws ssm get-document \
    --region "$region" \
    --name "$document_name" \
    --query 'Content' \
    --output text
}

default_host_management_role_setting() {
  aws ssm get-service-setting \
    --region "$region" \
    --setting-id "/ssm/managed-instance/default-ec2-instance-management-role" \
    --query 'ServiceSetting.SettingValue' \
    --output text
}

echo "Checking SSM Session Manager preferences in region: $region"

if ! document_content="$(session_doc_content 2>/dev/null)"; then
  echo "Non-compliant: Session Manager preferences document '${document_name}' not found (create/update it or run with --ssm-self-management)" >&2
  exit 1
fi

if ! echo "$document_content" | jq -e . >/dev/null; then
  echo "Non-compliant: Session Manager preferences document content is not valid JSON" >&2
  exit 1
fi

run_as_enabled="$(echo "$document_content" | jq -r '.inputs.runAsEnabled // ""')"
run_as_default_user="$(echo "$document_content" | jq -r '.inputs.runAsDefaultUser // ""')"
cloudwatch_log_group="$(echo "$document_content" | jq -r '.inputs.cloudWatchLogGroupName // ""')"
cloudwatch_streaming_enabled="$(echo "$document_content" | jq -r '.inputs.cloudWatchStreamingEnabled // false')"
cloudwatch_encryption_enabled="$(echo "$document_content" | jq -r '.inputs.cloudWatchEncryptionEnabled // false')"

if [[ "$run_as_enabled" != "true" ]]; then
  echo "Non-compliant: Session preferences inputs.runAsEnabled must be true" >&2
  exit 1
fi

if [[ -z "$run_as_default_user" ]]; then
  echo "Warning: Session preferences inputs.runAsDefaultUser is not set; Run As identity will rely on IAM principal tag SSMSessionRunAs."
fi

if [[ -z "$cloudwatch_log_group" ]]; then
  echo "Non-compliant: Session preferences inputs.cloudWatchLogGroupName must be set" >&2
  exit 1
fi

if [[ "$cloudwatch_streaming_enabled" != "true" ]]; then
  echo "Non-compliant: Session preferences inputs.cloudWatchStreamingEnabled must be true" >&2
  exit 1
fi

if [[ "$cloudwatch_log_group" != "$expected_log_group" ]]; then
  echo "Non-compliant: Session preferences cloudWatchLogGroupName '$cloudwatch_log_group' != expected '$expected_log_group'" >&2
  exit 1
fi

if ! default_host_role_setting="$(default_host_management_role_setting 2>/dev/null)"; then
  echo "Non-compliant: could not read SSM service setting '/ssm/managed-instance/default-ec2-instance-management-role'" >&2
  exit 1
fi

if [[ -z "$default_host_role_setting" || "$default_host_role_setting" == "None" ]]; then
  echo "Non-compliant: Default Host Management role is not configured (set '/ssm/managed-instance/default-ec2-instance-management-role' or run with --ssm-self-management)" >&2
  exit 1
fi

# SSM can reference a log group name that does not exist yet; ensure the group is present in CloudWatch.
log_group_match_count="$(aws logs describe-log-groups \
  --region "$region" \
  --log-group-name-prefix "$expected_log_group" \
  --query "length(logGroups[?logGroupName=='${expected_log_group}'])" \
  --output text)"
if [[ "${log_group_match_count:-0}" != "1" ]]; then
  echo "Non-compliant: CloudWatch log group '${expected_log_group}' not found (apply observability stack first)" >&2
  exit 1
fi

if [[ "$cloudwatch_encryption_enabled" == "true" ]]; then
  log_group_kms_key="$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$expected_log_group" \
    --query "logGroups[?logGroupName=='${expected_log_group}'].kmsKeyId | [0]" \
    --output text)"
  if [[ -z "$log_group_kms_key" || "$log_group_kms_key" == "None" ]]; then
    echo "Non-compliant: Session preferences require CloudWatch encryption, but log group '${expected_log_group}' has no kmsKeyId." >&2
    exit 1
  fi
fi

echo "SSM preflight checks passed."
