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
