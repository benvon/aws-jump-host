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
  ZIP_MEMBERS_LOG="$(mktemp)"
  export HOME="$HOME_DIR"
  export AWS_LOG ZIP_LOG ZIP_MEMBERS_LOG
  export JUMP_HOST_LOG_TRANSFER_BUCKET="jh-log-test"
  export JUMP_HOST_LOG_TRANSFER_REGION="us-west-2"
  export PATH="${FAKE_BIN}:${PATH}"
  export AWS_PROFILE=operator-sso
  export AWS_DEFAULT_PROFILE=operator-sso
  export AWS_ACCESS_KEY_ID=operator-key
  export AWS_SECRET_ACCESS_KEY=operator-secret
  export AWS_SESSION_TOKEN=operator-session
  export AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/should-not-use-web-identity
  export AWS_ROLE_ARN=arn:aws:iam::123456789012:role/should-not-use
  export AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/v2/credentials/should-not
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
  echo "EC2_METADATA_DISABLED=${AWS_EC2_METADATA_DISABLED-<unset>}"
  echo "WEB_IDENTITY_TOKEN_FILE=${AWS_WEB_IDENTITY_TOKEN_FILE-<unset>}"
  echo "ROLE_ARN=${AWS_ROLE_ARN-<unset>}"
  echo "CONTAINER_CREDS=${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI-<unset>}"
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
if [[ "${1:-}" == configure && "${2:-}" == get ]]; then
  shift 2
  name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) shift 2 ;;
      *) name="$1"; shift ;;
    esac
  done
  if [[ "$name" == s3.max_bandwidth && -n "${FAKE_S3_MAX_BANDWIDTH:-}" ]]; then
    printf '%s\n' "$FAKE_S3_MAX_BANDWIDTH"
    exit 0
  fi
  exit 1
fi
if [[ -n "${AWS_CONFIG_FILE:-}" && -f "${AWS_CONFIG_FILE}" ]]; then
  awk '
    /^\[/ { sec=$0; next }
    /^[[:space:]]*s3[[:space:]]*=/ {
      if (seen[sec]++) {
        print "duplicate s3 key in " sec > "/dev/stderr"
        exit 1
      }
    }
  ' "${AWS_CONFIG_FILE}" || exit 1
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
# Info-ZIP 3.0 default is add/replace: keep members already in the archive.
mkdir -p "$(dirname "$archive")"
touch "$archive"
for p in "${paths[@]+"${paths[@]}"}"; do
  # Info-ZIP: operand "-" is stdin even after "--".
  if [[ "$p" == - ]]; then
    printf 'STDIN\n' >>"$archive"
    continue
  fi
  printf '%s\n' "$p" >>"$archive"
done
{
  echo "ARCHIVE=$archive"
  echo "MEMBERS_BEGIN"
  cat "$archive"
  echo "MEMBERS_END"
} >>"${ZIP_MEMBERS_LOG}"
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
  rm -rf "${FAKE_BIN:-}" "${HOME_DIR:-}" "${SRC_DIR:-}" "${AWS_LOG:-}" "${ZIP_LOG:-}" "${ZIP_MEMBERS_LOG:-}"
}

# Process-local AWS_CONFIG_FILE dumped by the fake aws during `s3 cp`.
generated_config() {
  awk '/^CONFIG_BEGIN$/,/^CONFIG_END$/' "$AWS_LOG"
}

generated_config_has() {
  if generated_config | grep -qF "$1"; then
    return 0
  fi
  return 1
}

count_in_generated() {
  generated_config | grep -cF "$1" || true
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

@test "log-transfer uploads with multipart config, operator credentials, and console URL" {
  run "$LOG_TRANSFER" "$SRC_DIR/app.log" "$SRC_DIR/nested"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"https://s3.console.aws.amazon.com/s3/object/jh-log-test?region=us-west-2&prefix="* ]]
  [[ "$output" == *".zip"* ]]
  grep -q 's3 cp' "$AWS_LOG"
  grep -q 's3://jh-log-test/' "$AWS_LOG"
  grep -q -- '--only-show-errors' "$AWS_LOG"
  grep -q 'PROFILE=operator-sso' "$AWS_LOG"
  grep -q 'DEFAULT_PROFILE=operator-sso' "$AWS_LOG"
  grep -q 'ACCESS_KEY_ID=operator-key' "$AWS_LOG"
  grep -q 'SECRET_ACCESS_KEY=operator-secret' "$AWS_LOG"
  grep -q 'SESSION_TOKEN=operator-session' "$AWS_LOG"
  ! grep -q 'SHARED_CREDENTIALS_FILE=/dev/null' "$AWS_LOG"
  grep -q 'EC2_METADATA_DISABLED=true' "$AWS_LOG"
  grep -q 'WEB_IDENTITY_TOKEN_FILE=<unset>' "$AWS_LOG"
  grep -q 'ROLE_ARN=<unset>' "$AWS_LOG"
  grep -q 'CONTAINER_CREDS=<unset>' "$AWS_LOG"
  grep -q -- '--storage-class INTELLIGENT_TIERING' "$AWS_LOG"
  grep -q 'multipart_threshold = 16MB' "$AWS_LOG"
  grep -q 'multipart_chunksize = 64MB' "$AWS_LOG"
  ! find "$HOME_DIR/.cache/log-transfer" -name '*.zip' 2>/dev/null | grep -q .
}

@test "log-transfer constructs S3 settings without copying the operator AWS config" {
  mkdir -p "$HOME_DIR/.aws"
  cat >"$HOME_DIR/.aws/config" <<'EOF'
[profile operator-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = us-west-2
s3 =
    max_bandwidth = 10MB/s
region = us-west-2
EOF
  cp "$HOME_DIR/.aws/config" "$HOME_DIR/.aws/config.orig"
  export FAKE_S3_MAX_BANDWIDTH=10MB/s
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  cmp -s "$HOME_DIR/.aws/config" "$HOME_DIR/.aws/config.orig"
  ! grep -q 'sso_start_url' "$AWS_LOG"
  grep -q 'credential_process' "$AWS_LOG"
  grep -q 'PROFILE=operator-sso' "$AWS_LOG"
  grep -q 'multipart_threshold = 16MB' "$AWS_LOG"
  grep -q 'max_bandwidth = 10MB/s' "$AWS_LOG"
  [[ "$output" == *"max_bandwidth=10MB/s"* ]]
  grep -qE 's3://jh-log-test/[a-z0-9_]+/[0-9]{8}T[0-9]{6}Z-.+\.zip' "$AWS_LOG"
}

@test "log-transfer uploads when the operator AWS config uses CRLF" {
  mkdir -p "$HOME_DIR/.aws"
  printf '[profile operator-sso]\r\nsso_start_url = https://example.awsapps.com/start\r\ns3 =\r\n    max_bandwidth = 10MB/s\r\n' >"$HOME_DIR/.aws/config"
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *".zip"* ]]
  grep -qE 's3://jh-log-test/.+\.zip' "$AWS_LOG"
  ! grep -q 'sso_start_url' "$AWS_LOG"
}

@test "log-transfer writes one s3 block and does not copy operator profile keys" {
  mkdir -p "$HOME_DIR/.aws"
  cat >"$HOME_DIR/.aws/config" <<'EOF'
[profile operator-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = us-west-2
s3 =
    max_concurrent_requests = 20
    multipart_threshold = 8MB
region = us-west-2
EOF
  cp "$HOME_DIR/.aws/config" "$HOME_DIR/.aws/config.orig"
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"s3.console.aws.amazon.com"* ]]
  cmp -s "$HOME_DIR/.aws/config" "$HOME_DIR/.aws/config.orig"
  grep -q 'PROFILE=operator-sso' "$AWS_LOG"
  ! grep -q 'sso_start_url' "$AWS_LOG"
  grep -q 'credential_process' "$AWS_LOG"
  grep -q 'multipart_threshold = 16MB' "$AWS_LOG"
  ! grep -q 'multipart_threshold = 8MB' "$AWS_LOG"
  [[ "$(count_in_generated '[profile operator-sso]')" -eq 1 ]]
  [[ "$(count_in_generated 's3 =')" -eq 1 ]]
}

@test "log-transfer applies S3 settings to AWS_DEFAULT_PROFILE when AWS_PROFILE is unset" {
  unset AWS_PROFILE
  export AWS_DEFAULT_PROFILE=operator-sso
  mkdir -p "$HOME_DIR/.aws"
  cat >"$HOME_DIR/.aws/config" <<'EOF'
[default]
s3 =
    multipart_threshold = 8MB
[profile operator-sso]
sso_start_url = https://example.awsapps.com/start
region = us-west-2
EOF
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  grep -q 'PROFILE=<unset>' "$AWS_LOG"
  grep -q 'DEFAULT_PROFILE=operator-sso' "$AWS_LOG"
  ! generated_config_has '[default]'
  generated_config_has '[profile operator-sso]'
  generated_config_has 'multipart_threshold = 16MB'
  ! generated_config_has 'sso_start_url'
  [[ "$(count_in_generated 's3 =')" -eq 1 ]]
}

@test "log-transfer inherits profile S3 settings and prints the effective transfer config" {
  mkdir -p "$HOME_DIR/.aws"
  cat >"$HOME_DIR/.aws/config" <<'EOF'
[profile operator-sso]
sso_start_url = https://example.awsapps.com/start
s3 =
    max_concurrent_requests = 20
    multipart_threshold = 8MB
    max_bandwidth = 10MB/s
EOF
  export FAKE_S3_MAX_BANDWIDTH=10MB/s
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  [[ "$(count_in_generated 's3 =')" -eq 1 ]]
  generated_config_has 'multipart_threshold = 16MB'
  generated_config_has 'multipart_chunksize = 64MB'
  generated_config_has 'max_concurrent_requests = 4'
  generated_config_has 'max_bandwidth = 10MB/s'
  ! generated_config_has 'sso_start_url'
  [[ "$output" == *"multipart_threshold=16MB"* ]]
  [[ "$output" == *"multipart_chunksize=64MB"* ]]
  [[ "$output" == *"max_concurrent_requests=4"* ]]
  [[ "$output" == *"max_bandwidth=10MB/s"* ]]
  [[ "$output" != *"sso_start_url"* ]]
}

@test "log-transfer keeps the generated object key when inheriting S3 settings" {
  mkdir -p "$HOME_DIR/.aws"
  cat >"$HOME_DIR/.aws/config" <<'EOF'
[profile operator-sso]
s3 =
    max_concurrent_requests = 20
    multipart_threshold = 8MB
    max_bandwidth = 10MB/s
EOF
  export FAKE_S3_MAX_BANDWIDTH=10MB/s
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *".zip"* ]]
  [[ "$output" != *"prefix=max_bandwidth"* ]]
  [[ "$output" != *"prefix=multipart_threshold"* ]]
  grep -qE 's3://jh-log-test/[a-z0-9_]+/[0-9]{8}T[0-9]{6}Z-.+\.zip' "$AWS_LOG"
  ! grep -q 's3://jh-log-test/max_bandwidth' "$AWS_LOG"
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

@test "log-transfer object keys are unique when started in the same second" {
  cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
echo '20260115T120000Z'
EOF
  chmod +x "$FAKE_BIN/date"
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -eq 0 ]]
  key1="$(grep -o 's3://jh-log-test/[^[:space:]]*' "$AWS_LOG" | tail -n1)"
  : >"$AWS_LOG"
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -eq 0 ]]
  key2="$(grep -o 's3://jh-log-test/[^[:space:]]*' "$AWS_LOG" | tail -n1)"
  [[ -n "$key1" && -n "$key2" && "$key1" != "$key2" ]]
  [[ "$key1" =~ -[0-9a-f]{4}\.zip$ ]]
  [[ "$key2" =~ -[0-9a-f]{4}\.zip$ ]]
}

@test "log-transfer does not keep leftover zip members from a PID workspace" {
  leftover="$HOME_DIR/.cache/log-transfer/$$"
  mkdir -p "$leftover"
  printf 'stale-secret.log\n' >"$leftover/archive.zip"
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -eq 0 ]]
  ! grep -q 'stale-secret.log' "$ZIP_MEMBERS_LOG"
  grep -q 'app.log' "$ZIP_MEMBERS_LOG"
  archive_line="$(grep '^ARCHIVE=' "$ZIP_MEMBERS_LOG")"
  [[ "$archive_line" == *".cache/log-transfer/"* ]]
  [[ "$archive_line" == *"/run."* ]]
  ! [[ "$archive_line" =~ /log-transfer/[0-9]+/archive.zip ]]
}

@test "log-transfer archives a file named dash instead of reading stdin" {
  cd "$SRC_DIR"
  printf 'dashfile\n' >-
  run "$LOG_TRANSFER" -
  [[ "$status" -eq 0 ]]
  grep -q -- ' ./-' "$ZIP_LOG"
  grep -q './-' "$ZIP_MEMBERS_LOG"
  ! grep -q 'STDIN' "$ZIP_MEMBERS_LOG"
}

@test "log-transfer rejects an unsafe bucket name" {
  export JUMP_HOST_LOG_TRANSFER_BUCKET='jh-log-test;evil'
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"s3.console.aws.amazon.com"* ]]
}

@test "log-transfer rejects an unsafe region" {
  export JUMP_HOST_LOG_TRANSFER_REGION='us-west-2;evil'
  run "$LOG_TRANSFER" "$SRC_DIR/app.log"
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
