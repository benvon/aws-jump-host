#!/usr/bin/env bats
# Shared users.yaml schema: reject anything Ansible user_accounts would fail on,
# so log-transfer IAM is not applied for records that never get a Linux user.

setup() {
  VALID="$(mktemp)"
  cat >"$VALID" <<'EOF'
users:
  - username: alice
    groups:
      - wheel
    sudo_profile: ops
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
EOF
}

teardown() {
  rm -f "$VALID"
}

@test "validate_users_vars accepts a record Ansible would provision" {
  run ./scripts/validate_users_vars.py "$VALID"
  [[ "$status" -eq 0 ]]
}

@test "validate_users_vars accepts a missing state key as present" {
  run ./scripts/validate_users_vars.py "$VALID"
  [[ "$status" -eq 0 ]]
}

@test "validate_users_vars rejects groups that are not a list" {
  local f
  f="$(mktemp)"
  cat >"$f" <<'EOF'
users:
  - username: alice
    groups:
      ops: true
    sudo_profile: ops
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
EOF
  run ./scripts/validate_users_vars.py "$f"
  rm -f "$f"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"groups must be a list"* ]]
}

@test "validate_users_vars rejects an explicitly null state" {
  local f
  f="$(mktemp)"
  cat >"$f" <<'EOF'
users:
  - username: alice
    groups:
      - wheel
    sudo_profile: ops
    state:
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
EOF
  run ./scripts/validate_users_vars.py "$f"
  rm -f "$f"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"state must be present or absent"* ]]
}

@test "validate_users_vars rejects an explicitly null iam_role_arns" {
  local f
  f="$(mktemp)"
  cat >"$f" <<'EOF'
users:
  - username: alice
    groups:
      - wheel
    sudo_profile: ops
    iam_role_arns:
EOF
  run ./scripts/validate_users_vars.py "$f"
  rm -f "$f"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"iam_role_arns must be a list of strings"* ]]
}

@test "validate_users_vars rejects duplicate usernames" {
  local f
  f="$(mktemp)"
  cat >"$f" <<'EOF'
users:
  - username: alice
    groups:
      - wheel
    sudo_profile: ops
    iam_role_arns:
      - arn:aws:iam::123456789012:role/alice
  - username: alice
    groups:
      - wheel
    sudo_profile: ops
    state: absent
EOF
  run ./scripts/validate_users_vars.py "$f"
  rm -f "$f"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"duplicate username"* ]]
}

@test "validate_users_vars rejects an explicitly null users list" {
  local f
  f="$(mktemp)"
  printf 'users:\n' >"$f"
  run ./scripts/validate_users_vars.py "$f"
  rm -f "$f"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"users must be a list"* ]]
}
