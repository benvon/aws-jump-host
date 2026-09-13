#!/usr/bin/env bats
load helper

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
  rm -f "$log"
}

@test "orchestrate destroy without --auto-approve does not add -auto-approve" {
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
  [[ "$status" -eq 0 ]]
  run grep -qF 'destroy -auto-approve' "$log"
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
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
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
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
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
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  export FAKE_TG_OUTPUT_FAIL=1
  local ansible_log
  ansible_log="$(mktemp)"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"log-transfer"* ]]
  ! grep -q 'jump_host_log_transfer_bucket=' "$ansible_log"
  rm -f "$ansible_log"
}

@test "orchestrate plan skips log-transfer extra-vars when output lookup fails" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  export FAKE_TG_OUTPUT_FAIL=1
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
  grep -q 'jump_host_log_transfer_skip=true' "$ansible_log"
  ! grep -q 'jump_host_log_transfer_bucket=' "$ansible_log"
  rm -f "$log" "$ansible_log"
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
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
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
