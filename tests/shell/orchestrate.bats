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
