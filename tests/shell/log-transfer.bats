#!/usr/bin/env bats
# Tests for session_comfort log-transfer helper.

setup() {
  local repo_root
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$repo_root" || exit 1
  LOG_TRANSFER="$repo_root/ansible/roles/session_comfort/files/log-transfer"
  FAKE_BIN="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  SRC_DIR="$(mktemp -d)"
  AWS_LOG="$(mktemp)"
  ZIP_LOG="$(mktemp)"
  export HOME="$HOME_DIR"
  export AWS_LOG ZIP_LOG
  export JUMP_HOST_LOG_TRANSFER_BUCKET="jh-log-test"
  export JUMP_HOST_LOG_TRANSFER_REGION="us-west-2"
  export PATH="${FAKE_BIN}:${PATH}"
  export AWS_PROFILE=should-not-be-used
  export AWS_DEFAULT_PROFILE=also-should-not
  export AWS_ACCESS_KEY_ID=should-not-be-used
  export AWS_SECRET_ACCESS_KEY=also-should-not
  export AWS_SESSION_TOKEN=session-should-not
  printf 'hello\n' >"$SRC_DIR/app.log"
  mkdir -p "$SRC_DIR/nested"
  printf 'inner\n' >"$SRC_DIR/nested/a.txt"

  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
{
  echo "PROFILE=${AWS_PROFILE-<unset>}"
  echo "DEFAULT_PROFILE=${AWS_DEFAULT_PROFILE-<unset>}"
  echo "ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID-<unset>}"
  echo "SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY-<unset>}"
  echo "SESSION_TOKEN=${AWS_SESSION_TOKEN-<unset>}"
  echo "SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE-<unset>}"
  echo "CONFIG_FILE=${AWS_CONFIG_FILE-<unset>}"
  if [[ -n "${AWS_CONFIG_FILE:-}" && -f "${AWS_CONFIG_FILE}" ]]; then
    echo "CONFIG_BEGIN"
    cat "${AWS_CONFIG_FILE}"
    echo "CONFIG_END"
  fi
  printf 'ARGS '
  printf '%q ' "$@"
  printf '\n'
} >>"${AWS_LOG}"
if [[ "${FAKE_AWS_FAIL:-}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
  cat >"$FAKE_BIN/zip" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${ZIP_LOG}"
printf '\n' >>"${ZIP_LOG}"
archive=""
paths=()
move_mode=0
end_opts=0
while [[ $# -gt 0 ]]; do
  if [[ "$end_opts" -eq 0 ]]; then
    case "$1" in
      --) end_opts=1; shift; continue ;;
      -r) shift; continue ;;
      -m) move_mode=1; shift; continue ;;
    esac
  fi
  if [[ -z "$archive" ]]; then
    archive="$1"
  else
    paths+=("$1")
  fi
  shift
done
mkdir -p "$(dirname "$archive")"
: >"$archive"
for p in "${paths[@]+"${paths[@]}"}"; do
  printf '%s\n' "$p" >>"$archive"
done
[[ -s "$archive" ]] || exit 1
if [[ "$move_mode" -eq 1 ]]; then
  for p in "${paths[@]+"${paths[@]}"}"; do
    rm -rf "$p"
  done
fi
exit 0
EOF
  cat >"$FAKE_BIN/zipinfo" <<'EOF'
#!/usr/bin/env bash
archive=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -1) shift ;;
    *) archive="$1"; shift ;;
  esac
done
cat "$archive"
EOF
  chmod +x "$FAKE_BIN/aws" "$FAKE_BIN/zip" "$FAKE_BIN/zipinfo"
}

teardown() {
  rm -rf "${FAKE_BIN:-}" "${HOME_DIR:-}" "${SRC_DIR:-}" "${AWS_LOG:-}" "${ZIP_LOG:-}"
}

@test "log-transfer fails with no paths" {
  run "$LOG_TRANSFER"
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"s3.console.aws.amazon.com"* ]]
}

@test "log-transfer fails when a path is missing" {
  run "$LOG_TRANSFER" "$SRC_DIR/app.log" /no/such/path
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"s3.console.aws.amazon.com"* ]]
}

@test "log-transfer fails when bucket is not configured" {
  unset JUMP_HOST_LOG_TRANSFER_BUCKET
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"bucket"* ]]
  [[ "$output" != *"s3.console.aws.amazon.com"* ]]
}

@test "log-transfer uploads with multipart config, instance role, and console URL" {
  run "$LOG_TRANSFER" "$SRC_DIR/app.log" "$SRC_DIR/nested"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"https://s3.console.aws.amazon.com/s3/object/jh-log-test?region=us-west-2&prefix="* ]]
  [[ "$output" == *".zip"* ]]
  grep -q 's3 cp' "$AWS_LOG"
  grep -q 's3://jh-log-test/' "$AWS_LOG"
  grep -q -- '--only-show-errors' "$AWS_LOG"
  grep -q 'PROFILE=<unset>' "$AWS_LOG"
  grep -q 'DEFAULT_PROFILE=<unset>' "$AWS_LOG"
  grep -q 'ACCESS_KEY_ID=<unset>' "$AWS_LOG"
  grep -q 'SECRET_ACCESS_KEY=<unset>' "$AWS_LOG"
  grep -q 'SESSION_TOKEN=<unset>' "$AWS_LOG"
  grep -q 'SHARED_CREDENTIALS_FILE=/dev/null' "$AWS_LOG"
  grep -q -- '--storage-class INTELLIGENT_TIERING' "$AWS_LOG"
  grep -q 'multipart_threshold = 16MB' "$AWS_LOG"
  grep -q 'multipart_chunksize = 64MB' "$AWS_LOG"
  ! find "$HOME_DIR/.cache/log-transfer" -name '*.zip' 2>/dev/null | grep -q .
}

@test "log-transfer accepts large zip listings without SIGPIPE" {
  cat >"$FAKE_BIN/zipinfo" <<'EOF'
#!/usr/bin/env bash
archive=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -1) shift ;;
    *) archive="$1"; shift ;;
  esac
done
for i in $(seq 1 4000); do
  printf 'entry-%04d.txt\n' "$i"
done
printf '%s\n' "$archive"
EOF
  chmod +x "$FAKE_BIN/zipinfo"
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"s3.console.aws.amazon.com"* ]]
}

@test "log-transfer prints no URL when aws s3 cp fails" {
  FAKE_AWS_FAIL=1 run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"s3.console.aws.amazon.com"* ]]
}

@test "log-transfer terminates zip options before caller paths" {
  cd "$SRC_DIR"
  printf 'dash\n' >-m
  run "$LOG_TRANSFER" app.log -m
  [[ "$status" -eq 0 ]]
  [[ -f app.log ]]
  [[ -f ./-m ]]
  grep -q -- ' -- ' "$ZIP_LOG"
}
