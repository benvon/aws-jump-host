#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$REPO_ROOT" || exit 1
  FAKE_BIN="$(mktemp -d)"
  export PATH="${FAKE_BIN}:${PATH}"
}

teardown() {
  rm -rf "${FAKE_BIN:-}"
}

write_aws() {
  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ssm" && "${2:-}" == "get-document" ]]; then
  if [[ "${FAKE_AWS_DOCUMENT_FAIL:-}" == "1" ]]; then
    echo "document missing from aws" >&2
    exit 5
  fi
  cat <<'JSON'
{"inputs":{"runAsEnabled":true,"runAsDefaultUser":"ec2-user","cloudWatchLogGroupName":"/aws/ssm/jump-host/dev/east/us-east-1","cloudWatchStreamingEnabled":true,"cloudWatchEncryptionEnabled":false}}
JSON
  exit 0
fi
if [[ "${1:-}" == "ssm" && "${2:-}" == "get-service-setting" ]]; then
  echo "arn:aws:iam::111111111111:role/ssm-managed"
  exit 0
fi
if [[ "${1:-}" == "logs" && "${2:-}" == "describe-log-groups" ]]; then
  echo "1"
  exit 0
fi
echo "unhandled aws $*" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/aws"
}

@test "preflight document lookup failure shows aws stderr and the non-compliant line" {
  write_aws
  export FAKE_AWS_DOCUMENT_FAIL=1
  run ./scripts/preflight_ssm_compliance.sh \
    --region us-east-1 \
    --expected-log-group /aws/ssm/jump-host/dev/east/us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"document missing from aws"* ]]
  [[ "$output" == *"Non-compliant:"* ]]
  [[ "$output" == *"SSM-SessionManagerRunShell"* ]]
}

@test "preflight passes when the session document and log group match" {
  write_aws
  run ./scripts/preflight_ssm_compliance.sh \
    --region us-east-1 \
    --expected-log-group /aws/ssm/jump-host/dev/east/us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"SSM preflight checks passed."* ]]
}
