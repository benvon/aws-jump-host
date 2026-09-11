#!/usr/bin/env bats
# Tests for scripts/end-user/jump-host-ssm.sh (list/connect discovery).
# Run against every distinct Bash we can find: PATH bash (Linux/WSL/Homebrew)
# and /bin/bash (macOS 3.2, or the system Bash on Linux).

setup() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$REPO_ROOT" || exit 1
  FAKE_AWS_DIR="$(mktemp -d)"
  export FAKE_AWS_DIR
  cat >"$FAKE_AWS_DIR/aws" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *get-caller-identity*)
    echo '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/test","UserId":"AIDATEST"}'
    exit 0
    ;;
  *configure*get*region*)
    echo "us-west-2"
    exit 0
    ;;
  *describe-instances*)
    case "${FAKE_AWS_INSTANCES:-empty}" in
      one)
        printf 'i-0123456789abcdef0\tjump-core-01\tus-west-2a\n'
        ;;
      two)
        printf 'i-0123456789abcdef0\tjump-core-01\tus-west-2a\n'
        printf 'i-0fedcba9876543210\tjump-core-02\tus-west-2b\n'
        ;;
      empty | *)
        ;;
    esac
    exit 0
    ;;
  *)
    echo "unexpected aws invocation: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$FAKE_AWS_DIR/aws"
  export PATH="${FAKE_AWS_DIR}:${PATH}"
  export AWS_REGION=us-west-2
  unset AWS_PROFILE || true
}

teardown() {
  rm -rf "${FAKE_AWS_DIR:-}"
}

# PATH `bash` plus `/bin/bash` when they resolve to different files.
bash_interpreters() {
  local cand resolved prev=""
  for cand in bash /bin/bash; do
    resolved="$(command -v "$cand" 2>/dev/null || true)"
    [[ -n "$resolved" && -x "$resolved" && "$resolved" != "$prev" ]] || continue
    prev="$resolved"
    printf '%s\n' "$resolved"
  done
}

run_list() {
  local bash_bin="$1"
  shift
  run "$bash_bin" ./scripts/end-user/jump-host-ssm.sh list "$@"
  echo "interpreter=$bash_bin version=$("$bash_bin" -c 'echo "$BASH_VERSION"')"
  echo "status=$status output=$output"
}

@test "list with no --tag and no instances succeeds on every bash" {
  export FAKE_AWS_INSTANCES=empty
  local bin
  while IFS= read -r bin; do
    run_list "$bin" --region us-west-2
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No matching running jump hosts (JumpHost=true)."* ]]
    [[ "$output" != *"unbound variable"* ]]
    [[ "$output" != *"unary operator expected"* ]]
  done < <(bash_interpreters)
}

@test "list with --tag and no instances succeeds on every bash" {
  export FAKE_AWS_INSTANCES=empty
  local bin
  while IFS= read -r bin; do
    run_list "$bin" --region us-west-2 --tag Environment=stage
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"with given --tag filters"* ]]
    [[ "$output" != *"unbound variable"* ]]
  done < <(bash_interpreters)
}

@test "list prints matching instances on every bash" {
  export FAKE_AWS_INSTANCES=two
  local bin
  while IFS= read -r bin; do
    run_list "$bin" --region us-west-2
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"INSTANCE_ID"* ]]
    [[ "$output" == *"i-0123456789abcdef0"* ]]
    [[ "$output" == *"jump-core-01"* ]]
    [[ "$output" == *"i-0fedcba9876543210"* ]]
    [[ "$output" == *"jump-core-02"* ]]
  done < <(bash_interpreters)
}

@test "list --name-contains filters instance name tags on every bash" {
  export FAKE_AWS_INSTANCES=two
  local bin
  while IFS= read -r bin; do
    run_list "$bin" --region us-west-2 --name-contains core-02
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"i-0fedcba9876543210"* ]]
    [[ "$output" != *"i-0123456789abcdef0"* ]]
  done < <(bash_interpreters)
}

@test "list with --tag prints instances on every bash" {
  export FAKE_AWS_INSTANCES=one
  local bin
  while IFS= read -r bin; do
    run_list "$bin" --region us-west-2 --tag Environment=stage
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"i-0123456789abcdef0"* ]]
    [[ "$output" == *"jump-core-01"* ]]
  done < <(bash_interpreters)
}
