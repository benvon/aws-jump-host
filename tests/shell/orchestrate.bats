#!/usr/bin/env bats
load helper

install_aws_stub() {
  FAKE_BIN="$(mktemp -d)"
  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_AWS_LOG:-}" ]]; then
  printf '%q ' "$@" >>"$FAKE_AWS_LOG"
  echo >>"$FAKE_AWS_LOG"
fi
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
  if [[ "${FAKE_AWS_STS_FAIL:-}" == "1" ]]; then
    echo "sts exploded" >&2
    exit 4
  fi
  echo "${FAKE_AWS_ACCOUNT:-111111111111}"
  exit 0
fi
if [[ "${1:-}" == "s3api" && "${2:-}" == "head-bucket" ]]; then
  exit 0
fi
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
  export PATH="${FAKE_BIN}:${PATH}"
  local repo_root="${REPO_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
  local ssm_plugin_path="${repo_root}/ansible/collections/ansible_collections/amazon/aws/plugins/connection/aws_ssm.py"
  if [[ -f "$ssm_plugin_path" ]]; then
    return 0
  fi
  AWS_STUB_SSM_PLUGIN_PATH="$ssm_plugin_path"
  AWS_STUB_CREATED_DIRS_FILE="$(mktemp)"
  local plugin_dir parent_dir
  plugin_dir="$(dirname "$ssm_plugin_path")"
  parent_dir="$plugin_dir"
  while [[ ! -d "$parent_dir" ]]; do
    echo "$parent_dir" >>"$AWS_STUB_CREATED_DIRS_FILE"
    parent_dir="$(dirname "$parent_dir")"
  done
  mkdir -p "$plugin_dir"
  touch "$ssm_plugin_path"
}

teardown() {
  unset FAKE_TG_OUTPUT_FAIL FAKE_TG_BUCKET FAKE_TG_REGION || true
  unset SKIP_ACCOUNT_CHECK SKIP_PREFLIGHT FAKE_AWS_STS_FAIL FAKE_AWS_ACCOUNT FAKE_AWS_DOCUMENT_FAIL || true
  unset JUMP_HOST_USERS_VARS FAKE_ANSIBLE_LOG FAKE_TG_LOG || true
  if [[ -n "${FAKE_BIN:-}" ]]; then
    rm -rf "$FAKE_BIN"
    unset FAKE_BIN || true
  fi
  if [[ -n "${AWS_STUB_SSM_PLUGIN_PATH:-}" ]]; then
    rm -f "$AWS_STUB_SSM_PLUGIN_PATH"
    if [[ -f "${AWS_STUB_CREATED_DIRS_FILE:-}" ]]; then
      while IFS= read -r dir; do
        rmdir "$dir" 2>/dev/null || true
      done <"$AWS_STUB_CREATED_DIRS_FILE"
      rm -f "$AWS_STUB_CREATED_DIRS_FILE"
    fi
    unset AWS_STUB_SSM_PLUGIN_PATH AWS_STUB_CREATED_DIRS_FILE || true
  fi
}

@test "orchestrate exits non-zero with no arguments" {
  run ./scripts/orchestrate.sh
  [[ "$status" -ne 0 ]]
}

@test "orchestrate rejects unknown arguments" {
  run ./scripts/orchestrate.sh plan --live-dir ./examples/live --env dev --subenv east --region us-east-1 --not-a-real-flag
  [[ "$status" -ne 0 ]]
}

@test "orchestrate requires existing live stack directories" {
  run ./scripts/orchestrate.sh plan --live-dir /nonexistent/path --env dev --subenv east --region us-east-1
  [[ "$status" -ne 0 ]]
}

@test "orchestrate destroy passes -auto-approve to terragrunt when --auto-approve set" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --auto-approve
  [[ "$status" -eq 0 ]]
  grep -q -- '-auto-approve' "$log" || grep -q -- 'auto-approve' "$log"
  grep -q -- '-input=false' "$log"
  rm -f "$log"
}

@test "apply without a terminal exits before terragrunt" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh apply \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--non-interactive"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}

@test "destroy without a terminal exits before terragrunt" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--non-interactive"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}

@test "non-interactive destroy passes -auto-approve and -input=false" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive
  [[ "$status" -eq 0 ]]
  grep -q -- '-auto-approve' "$log"
  grep -q -- '-input=false' "$log"
  rm -f "$log"
}

@test "destroy on a terminal omits -auto-approve" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run python3 -c 'import os, pty, sys
status = pty.spawn(["./scripts/orchestrate.sh", "destroy", "--live-dir", "./examples/live", "--env", "dev", "--subenv", "east", "--region", "us-east-1"])
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(1)'
  [[ "$status" -eq 0 ]]
  grep -q 'destroy -input=false' "$log"
  run grep -qF -- '-auto-approve' "$log"
  [[ "$status" -ne 0 ]]
  rm -f "$log"
}

@test "orchestrate init includes ssm-self-management stack when enabled" {
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh init \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --ssm-self-management
  [[ "$status" -eq 0 ]]
  grep -q -- 'ssm-self-management' "$log"
  rm -f "$log"
}

@test "orchestrate plan runs log-transfer after jump-hosts" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log ansible_log
  log="$(mktemp)"
  ansible_log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
j = text.find("jump-hosts")
l = text.find("log-transfer")
assert j != -1 and l != -1 and j < l, text
' "$log"
  grep -q 'jump_host_log_transfer_bucket=example-log-transfer-bucket' "$ansible_log"
  grep -q 'jump_host_log_transfer_region=us-east-1' "$ansible_log"
  rm -f "$log" "$ansible_log"
}

@test "orchestrate destroy runs log-transfer before jump-hosts" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --auto-approve
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
l = text.find("log-transfer")
j = text.find("jump-hosts")
assert l != -1 and j != -1 and l < j, text
' "$log"
  rm -f "$log"
}

@test "orchestrate without --users-vars clears inherited JUMP_HOST_USERS_VARS" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  export JUMP_HOST_USERS_VARS="/this/should/not/be/used.yml"
  local log ansible_log
  log="$(mktemp)"
  ansible_log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  ! grep -q '/this/should/not/be/used.yml' "$log"
  ! grep -q '/this/should/not/be/used.yml' "$ansible_log"
  grep -q 'JUMP_HOST_ORCHESTRATE=1' "$log"
  grep -q '^JUMP_HOST_USERS_VARS=$' "$log"
  grep -q "JUMP_HOST_USERS_VALIDATOR=${REPO_ROOT}/scripts/validate_users_vars.py" "$log"
  rm -f "$log" "$ansible_log"
}

@test "orchestrate rejects a users file whose groups are not a list" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log users
  log="$(mktemp)"
  users="$(mktemp)"
  cat >"$users" <<'EOF'
users:
  - username: alice
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
    groups:
      ops: true
    sudo_profile: ops
EOF
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"user schema"* ]]
  [[ "$output" == *"groups must be a list"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log" "$users"
}

@test "orchestrate rejects a users file whose state is explicitly null" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log users
  log="$(mktemp)"
  users="$(mktemp)"
  cat >"$users" <<'EOF'
users:
  - username: alice
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
    groups:
      - wheel
    sudo_profile: ops
    state:
EOF
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"user schema"* ]]
  [[ "$output" == *"state"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log" "$users"
}

@test "orchestrate rejects an invalid Linux username before terragrunt" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log users
  log="$(mktemp)"
  users="$(mktemp)"
  cat >"$users" <<'EOF'
users:
  - username: alice bob
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
    groups:
      - wheel
    sudo_profile: ops
EOF
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Linux"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log" "$users"
}

@test "orchestrate rejects duplicate usernames before terragrunt" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log users
  log="$(mktemp)"
  users="$(mktemp)"
  cat >"$users" <<'EOF'
users:
  - username: alice
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
    groups:
      - wheel
    sudo_profile: ops
  - username: alice
    groups:
      - wheel
    sudo_profile: ops
    state: absent
EOF
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"duplicate username"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log" "$users"
}

@test "orchestrate rejects a users file that fails the Ansible user schema" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log users
  log="$(mktemp)"
  users="$(mktemp)"
  cat >"$users" <<'EOF'
users:
  - username: alice
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
    sudo_profile: ops
EOF
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"user schema"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log" "$users"
}

@test "orchestrate exports JUMP_HOST_USERS_VARS and JUMP_HOST_USERS_VALIDATOR" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log ansible_log users
  log="$(mktemp)"
  ansible_log="$(mktemp)"
  users="$(mktemp)"
  printf 'users: []\n' >"$users"
  export FAKE_TG_LOG="$log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users"
  [[ "$status" -eq 0 ]]
  grep -q "JUMP_HOST_USERS_VARS=${users}" "$log"
  grep -q "JUMP_HOST_USERS_VALIDATOR=${REPO_ROOT}/scripts/validate_users_vars.py" "$log"
  rm -f "$log" "$ansible_log" "$users"
}

@test "orchestrate configure fails when log-transfer outputs cannot be read" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  export FAKE_TG_OUTPUT_FAIL=1
  local ansible_log
  ansible_log="$(mktemp)"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"log-transfer"* ]]
  ! grep -q 'jump_host_log_transfer_bucket=' "$ansible_log"
  rm -f "$ansible_log"
}

@test "orchestrate plan fails when log-transfer outputs cannot be read" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  export FAKE_TG_OUTPUT_FAIL=1
  local ansible_log
  ansible_log="$(mktemp)"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"log-transfer"* ]]
  [[ "$output" == *"Error: command failed"* ]]
  [[ "$output" == *"unavailable"* ]]
  [[ ! -s "$ansible_log" ]]
  rm -f "$ansible_log"
}

@test "orchestrate rejects a missing --users-vars file" {
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars /nonexistent/jump-host-users.yml
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"users vars file not found"* ]]
}

@test "orchestrate configure applies log-transfer before ansible" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log ansible_log
  log="$(mktemp)"
  ansible_log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --auto-approve
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert "log-transfer" in text, text
assert "apply" in text, text
' "$log"
  grep -q 'jump_host_log_transfer_bucket=example-log-transfer-bucket' "$ansible_log"
  rm -f "$log" "$ansible_log"
}

@test "orchestrate configure rejects an unsafe log-transfer bucket output" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  export FAKE_TG_BUCKET='example-log-transfer-bucket;evil'
  local ansible_log
  ansible_log="$(mktemp)"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive
  [[ "$status" -ne 0 ]]
  ! grep -q 'jump_host_log_transfer_bucket=' "$ansible_log"
  rm -f "$ansible_log"
}

@test "orchestrate plan fails when account.hcl is missing" {
  install_aws_stub
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/dev/east/us-east-1"/{observability,vpc-endpoints,jump-hosts,log-transfer}
  run ./scripts/orchestrate.sh plan \
    --live-dir "$root" \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: account.hcl not found:"* ]]
  rm -rf "$root"
}

@test "orchestrate plan fails when account_id cannot be parsed" {
  install_aws_stub
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/dev/east/us-east-1"/{observability,vpc-endpoints,jump-hosts,log-transfer}
  printf 'locals {\n  account_id = "not-an-account"\n}\n' >"$root/dev/account.hcl"
  run ./scripts/orchestrate.sh plan \
    --live-dir "$root" \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: could not parse a 12-digit account_id from "* ]]
  rm -rf "$root"
}

@test "orchestrate plan preserves STS stderr and status" {
  install_aws_stub
  export FAKE_AWS_STS_FAIL=1
  export SKIP_PREFLIGHT=true
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"sts exploded"* ]]
  [[ "$output" == *"Error: command failed (exit 4):"* ]]
}

@test "orchestrate plan fails on account mismatch" {
  install_aws_stub
  export FAKE_AWS_ACCOUNT=999999999999
  export SKIP_PREFLIGHT=true
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: AWS account mismatch"* ]]
  [[ "$output" == *"999999999999"* ]]
  [[ "$output" == *"111111111111"* ]]
}

@test "orchestrate plan confirms a matching account" {
  install_aws_stub
  export FAKE_AWS_ACCOUNT=111111111111
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Account identity confirmed: 111111111111"* ]]
}

@test "SKIP_ACCOUNT_CHECK prints the skip line" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  run ./scripts/orchestrate.sh init \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Skipping account identity check (SKIP_ACCOUNT_CHECK=true)."* ]]
}

@test "plan apply and configure fail when the inventory is empty" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local command_name
  for command_name in plan apply configure; do
    local log ansible_log
    log="$(mktemp)"
    ansible_log="$(mktemp)"
    export FAKE_TG_LOG="$log"
    export FAKE_ANSIBLE_LOG="$ansible_log"
    if [[ "$command_name" == "plan" ]]; then
      run ./scripts/orchestrate.sh "$command_name" \
        --live-dir ./examples/live \
        --env dev \
        --subenv east \
        --region us-east-1
    else
      run ./scripts/orchestrate.sh "$command_name" \
        --live-dir ./examples/live \
        --env dev \
        --subenv east \
        --region us-east-1 \
        --non-interactive
    fi
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"0 jump hosts"* ]]
    [[ ! -s "$ansible_log" ]]
    rm -f "$log" "$ansible_log"
  done
}

@test "destroy with zero hosts skips decommission and still destroys stacks" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log ansible_log users
  log="$(mktemp)"
  ansible_log="$(mktemp)"
  users="$(mktemp)"
  printf 'users: []\n' >"$users"
  export FAKE_TG_LOG="$log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users" \
    --non-interactive
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"inventory has 0 jump hosts; skipping decommission."* ]]
  grep -q 'destroy -auto-approve' "$log"
  [[ ! -s "$ansible_log" ]]
  rm -f "$log" "$ansible_log" "$users"
}

@test "plan does not apply stacks" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --ssm-self-management
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert "ssm-self-management" in text, text
assert "plan" in text, text
for line in text.splitlines():
    assert "apply" not in line.split(), line
' "$log"
  [[ "$output" == *"does not create the CloudWatch log group"* ]]
  rm -f "$log"
}

@test "plan stops before terragrunt when preflight cannot read the session document" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_AWS_DOCUMENT_FAIL=1
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"document missing from aws"* ]]
  [[ "$output" == *"plan does not create the CloudWatch log group"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}

@test "apply runs observability before the other stacks" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh apply \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive \
    --ssm-self-management
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
lines = [line for line in text.splitlines() if "apply" in line.split()]
joined = "\n".join(lines)
obs = joined.find("observability")
ssm = joined.find("ssm-self-management")
ep = joined.find("vpc-endpoints")
jump = joined.find("jump-hosts")
log_transfer = joined.find("log-transfer")
assert -1 not in (obs, ssm, ep, jump, log_transfer), joined
assert obs < ssm < ep < jump < log_transfer, joined
assert joined.count("observability") == 1, joined
' "$log"
  grep -q -- '-auto-approve' "$log"
  grep -q -- '-input=false' "$log"
  rm -f "$log"
}

@test "configure applies log-transfer and not observability" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert "log-transfer" in text, text
assert "observability" not in text, text
for line in text.splitlines():
    parts = line.split()
    if "apply" in parts:
        assert "log-transfer" in line, line
' "$log"
  rm -f "$log"
}

@test "configure rejects --ssm-self-management" {
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive \
    --ssm-self-management
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--ssm-self-management"* ]]
  [[ "$output" == *"init, plan, or apply"* ]]
}

@test "destroy rejects --ssm-self-management" {
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive \
    --ssm-self-management
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--ssm-self-management"* ]]
  [[ "$output" == *"init, plan, or apply"* ]]
}

@test "validate runs terraform, terragrunt hcl validate, and ansible syntax-check" {
  local tf_log tg_log ansible_log
  tf_log="$(mktemp)"
  tg_log="$(mktemp)"
  ansible_log="$(mktemp)"
  export FAKE_TERRAFORM_LOG="$tf_log"
  export FAKE_TG_LOG="$tg_log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh validate
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"offline repository validation"* ]]
  grep -q 'validate' "$tf_log"
  grep -q 'hcl' "$tg_log"
  grep -q -- '--syntax-check' "$ansible_log"
  [[ "$(grep -c -- '--syntax-check' "$ansible_log")" -eq 2 ]]
  rm -f "$tf_log" "$tg_log" "$ansible_log"
}

@test "validate stops at the first failing terraform validate" {
  local tf_log tg_log
  tf_log="$(mktemp)"
  tg_log="$(mktemp)"
  export FAKE_TERRAFORM_LOG="$tf_log"
  export FAKE_TG_LOG="$tg_log"
  export FAKE_TERRAFORM_FAIL=1
  run ./scripts/orchestrate.sh validate
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"terraform validate exploded"* ]]
  [[ "$output" == *"Error: command failed (exit 2):"* ]]
  [[ "$(grep -c validate "$tf_log")" -eq 1 ]]
  [[ ! -s "$tg_log" ]]
  rm -f "$tf_log" "$tg_log"
}

@test "validate rejects --ssm-self-management" {
  run ./scripts/orchestrate.sh validate --ssm-self-management
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--ssm-self-management"* ]]
  [[ "$output" == *"init, plan, or apply"* ]]
  [[ "$output" != *"offline repository validation"* ]]
}

@test "check names validate and plan and does not run terragrunt" {
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh check
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"validate"* ]]
  [[ "$output" == *"plan"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}
