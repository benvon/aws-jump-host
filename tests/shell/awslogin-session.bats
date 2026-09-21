#!/usr/bin/env bats
# Tests for jump-host AWS session isolation (profile.d + awslogin).

setup() {
  local repo_root
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$repo_root" || exit 1
  SESSION_SH="$repo_root/ansible/roles/session_comfort/files/jump-host-aws-session.sh"
  AWSLOGIN="$repo_root/ansible/roles/session_comfort/files/awslogin"
  HOME_DIR="$(mktemp -d)"
  FAKE_BIN="$(mktemp -d)"
  AWS_LOG="$(mktemp)"
  export HOME="$HOME_DIR"
  export AWS_LOG
  export PATH="${FAKE_BIN}:${PATH}"
  unset JUMP_HOST_AWS_HOME JUMP_HOST_AWS_SESSION_ID AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_PROFILE || true
  mkdir -p "$HOME_DIR/.aws"
  cat >"$HOME_DIR/.aws/config" <<'EOF'
[profile jump-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = us-west-2
sso_account_id = 123456789012
sso_role_name = YourPermissionSet
region = us-west-2
EOF
}

teardown() {
  rm -rf "${HOME_DIR:-}" "${FAKE_BIN:-}" "${AWS_LOG:-}"
}

# Stub id -un for shared vs non-shared cases via FAKE_BIN/id
install_id_stub() {
  local user="$1"
  cat >"$FAKE_BIN/id" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -un ]]; then
  printf '%s\\n' '$user'
  exit 0
fi
exec /usr/bin/id "\$@"
EOF
  chmod +x "$FAKE_BIN/id"
}

# profile.d only runs for interactive shells; use bash -ic in tests.
source_session_exports() {
  bash -ic "
    export HOME=\"$HOME_DIR\"
    export PATH=\"$FAKE_BIN:\${PATH}\"
    unset JUMP_HOST_AWS_HOME JUMP_HOST_AWS_SESSION_ID AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_PROFILE
    source \"$SESSION_SH\"
    printf 'export JUMP_HOST_AWS_HOME=%q\n' \"\${JUMP_HOST_AWS_HOME:-}\"
    printf 'export JUMP_HOST_AWS_SESSION_ID=%q\n' \"\${JUMP_HOST_AWS_SESSION_ID:-}\"
    printf 'export AWS_CONFIG_FILE=%q\n' \"\${AWS_CONFIG_FILE:-}\"
    printf 'export AWS_SHARED_CREDENTIALS_FILE=%q\n' \"\${AWS_SHARED_CREDENTIALS_FILE:-}\"
  "
}

@test "profile.d is a no-op for non-shared users" {
  install_id_stub alice
  eval "$(source_session_exports)"
  [[ -z "${JUMP_HOST_AWS_HOME:-}" ]]
  [[ -z "${AWS_CONFIG_FILE:-}" ]]
  [[ -z "${AWS_SHARED_CREDENTIALS_FILE:-}" ]]
  ! [[ -d "$HOME_DIR/.cache/jump-host-aws" ]] || [[ -z "$(find "$HOME_DIR/.cache/jump-host-aws" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]
}

@test "profile.d creates session AWS home and exports for ec2-user" {
  install_id_stub ec2-user
  # Assertions run before subshell exit so the EXIT trap does not remove the tree first.
  bash -ic "
    set -e
    export HOME=\"$HOME_DIR\"
    export PATH=\"$FAKE_BIN:\${PATH}\"
    unset JUMP_HOST_AWS_HOME JUMP_HOST_AWS_SESSION_ID AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_PROFILE
    source \"$SESSION_SH\"
    [[ -n \"\${JUMP_HOST_AWS_HOME:-}\" ]]
    [[ -n \"\${JUMP_HOST_AWS_SESSION_ID:-}\" ]]
    [[ \"\$AWS_CONFIG_FILE\" == \"\$JUMP_HOST_AWS_HOME/.aws/config\" ]]
    [[ \"\$AWS_SHARED_CREDENTIALS_FILE\" == \"\$JUMP_HOST_AWS_HOME/.aws/credentials\" ]]
    [[ -f \"\$AWS_CONFIG_FILE\" ]]
    grep -q 'sso_start_url' \"\$AWS_CONFIG_FILE\"
    mode=\$(stat -f '%Lp' \"\$JUMP_HOST_AWS_HOME\" 2>/dev/null || stat -c '%a' \"\$JUMP_HOST_AWS_HOME\")
    [[ \"\$mode\" == '700' ]]
    trap - EXIT
  "
}

@test "profile.d EXIT trap removes the session directory for ec2-user" {
  install_id_stub ec2-user
  marker_file="$(mktemp)"
  bash -ic "
    set -euo pipefail
    export HOME=\"$HOME_DIR\"
    export PATH=\"$FAKE_BIN:\${PATH}\"
    unset JUMP_HOST_AWS_HOME JUMP_HOST_AWS_SESSION_ID AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_PROFILE
    source \"$SESSION_SH\"
    test -d \"\$JUMP_HOST_AWS_HOME\"
    printf '%s' \"\$JUMP_HOST_AWS_HOME\" > \"$marker_file\"
  "
  marker="$(cat "$marker_file")"
  rm -f "$marker_file"
  ! [[ -d "$marker" ]]
}

install_fake_aws() {
  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
{
  echo "HOME=${HOME-<unset>}"
  echo "CONFIG_FILE=${AWS_CONFIG_FILE-<unset>}"
  echo "CREDS_FILE=${AWS_SHARED_CREDENTIALS_FILE-<unset>}"
  printf 'ARGS '
  printf '%q ' "$@"
  printf '\n'
} >>"${AWS_LOG}"
if [[ "${1:-}" == configure && "${2:-}" == export-credentials ]]; then
  for arg in "$@"; do
    if [[ "$arg" == env-no-export ]]; then
      cat <<'ENV'
AWS_ACCESS_KEY_ID=ASIATESTACCESS
AWS_SECRET_ACCESS_KEY=testsecret
AWS_SESSION_TOKEN=testsession
ENV
      exit 0
    fi
  done
  cat <<'JSON'
{
  "Version": 1,
  "AccessKeyId": "ASIATESTACCESS",
  "SecretAccessKey": "testsecret",
  "SessionToken": "testsession",
  "Expiration": "2099-01-01T00:00:00Z"
}
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/aws"
}

@test "awslogin without session env keeps device-code SSO login only" {
  install_fake_aws
  export AWS_PROFILE=jump-sso
  unset JUMP_HOST_AWS_HOME AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  run "$AWSLOGIN"
  [[ "$status" -eq 0 ]]
  grep -q 'sso login' "$AWS_LOG"
  ! grep -q 'export-credentials' "$AWS_LOG"
}

@test "awslogin with session env logs in under session HOME and writes credentials" {
  install_id_stub ec2-user
  install_fake_aws
  eval "$(source_session_exports)"
  export AWS_PROFILE=jump-sso
  durable_before="$(cksum "$HOME_DIR/.aws/config")"
  run "$AWSLOGIN"
  echo "status=$status output=$output log=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  grep -q 'sso login' "$AWS_LOG"
  grep -q 'export-credentials' "$AWS_LOG"
  grep -q "HOME=${JUMP_HOST_AWS_HOME}" "$AWS_LOG"
  [[ -s "$AWS_SHARED_CREDENTIALS_FILE" ]]
  grep -q 'ASIATESTACCESS' "$AWS_SHARED_CREDENTIALS_FILE"
  grep -q '\[jump-sso\]' "$AWS_SHARED_CREDENTIALS_FILE"
  ! grep -q 'sso_start_url' "$AWS_CONFIG_FILE"
  grep -q 'region = us-west-2' "$AWS_CONFIG_FILE"
  [[ "$(cksum "$HOME_DIR/.aws/config")" == "$durable_before" ]]
  grep -q 'sso_start_url' "$HOME_DIR/.aws/config"
}
