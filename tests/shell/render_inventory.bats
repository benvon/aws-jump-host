#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
load helper

@test "render_inventory maps hosts from output -json hosts" {
  export FAKE_TG_SCENARIO=hosts_ok
  local out
  out="$(mktemp)"
  run ./scripts/render_inventory.sh \
    --terragrunt-dir "$REPO_ROOT/examples/live/dev/east/us-east-1/jump-hosts" \
    --output "$out"
  [[ "$status" -eq 0 ]]
  run jq -e '.all.children.jump_hosts.hosts["i-abc"].host_name == "core-01" and .all.children.jump_hosts.hosts["i-abc"].access_profile == "ops"' "$out"
  [[ "$status" -eq 0 ]]
  rm -f "$out"
}

@test "render_inventory falls back to hosts from full output -json" {
  export FAKE_TG_SCENARIO=via_all_json
  local out
  out="$(mktemp)"
  run ./scripts/render_inventory.sh \
    --terragrunt-dir "$REPO_ROOT/examples/live/dev/east/us-east-1/jump-hosts" \
    --output "$out"
  [[ "$status" -eq 0 ]]
  run jq -e '.all.children.jump_hosts.hosts["i-h1"].host_name == "h1"' "$out"
  [[ "$status" -eq 0 ]]
  rm -f "$out"
}

@test "render_inventory uses empty inventory when state is empty" {
  export FAKE_TG_SCENARIO=empty_state
  local out
  out="$(mktemp)"
  run ./scripts/render_inventory.sh \
    --terragrunt-dir "$REPO_ROOT/examples/live/dev/east/us-east-1/jump-hosts" \
    --output "$out"
  [[ "$status" -eq 0 ]]
  run jq -e '.all.children.jump_hosts.hosts | length == 0' "$out"
  [[ "$status" -eq 0 ]]
  rm -f "$out"
}

@test "render_inventory uses empty inventory when state is unavailable" {
  export FAKE_TG_SCENARIO=no_state
  local out
  out="$(mktemp)"
  run ./scripts/render_inventory.sh \
    --terragrunt-dir "$REPO_ROOT/examples/live/dev/east/us-east-1/jump-hosts" \
    --output "$out"
  [[ "$status" -eq 0 ]]
  run jq -e '.all.children.jump_hosts.hosts | length == 0' "$out"
  [[ "$status" -eq 0 ]]
  rm -f "$out"
}

@test "render_inventory fails when state has resources but hosts output is missing" {
  export FAKE_TG_SCENARIO=stale_state
  local out
  out="$(mktemp)"
  run ./scripts/render_inventory.sh \
    --terragrunt-dir "$REPO_ROOT/examples/live/dev/east/us-east-1/jump-hosts" \
    --output "$out"
  [[ "$status" -ne 0 ]]
  rm -f "$out"
}
