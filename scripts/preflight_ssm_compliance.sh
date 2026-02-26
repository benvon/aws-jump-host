#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --region <aws-region> --expected-log-group <name>

Validates externally managed SSM Session Manager service settings required by this solution.
USAGE
}

region=""
expected_log_group=""

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

setting_value() {
  local setting_id="$1"
  aws ssm get-service-setting \
    --region "$region" \
    --setting-id "$setting_id" \
    --query 'ServiceSetting.SettingValue' \
    --output text
}

echo "Checking SSM Session Manager service settings in region: $region"

run_as_enabled="$(setting_value /ssm/sessionmanager/enableRunAs)"
cloudwatch_enabled="$(setting_value /ssm/sessionmanager/enableCloudWatchLogging)"
cloudwatch_log_group="$(setting_value /ssm/sessionmanager/cloudWatchLogGroupName)"

if [[ "$run_as_enabled" != "true" ]]; then
  echo "Non-compliant: /ssm/sessionmanager/enableRunAs must be true" >&2
  exit 1
fi

if [[ "$cloudwatch_enabled" != "true" ]]; then
  echo "Non-compliant: /ssm/sessionmanager/enableCloudWatchLogging must be true" >&2
  exit 1
fi

if [[ "$cloudwatch_log_group" != "$expected_log_group" ]]; then
  echo "Non-compliant: cloudWatchLogGroupName '$cloudwatch_log_group' != expected '$expected_log_group'" >&2
  exit 1
fi

echo "SSM preflight checks passed."
