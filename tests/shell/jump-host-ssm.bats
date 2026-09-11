#!/usr/bin/env bats
# Tests for scripts/end-user/jump-host-ssm.sh (list/connect discovery).

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

run_list() {
  local bash_bin="$1"
  shift
  run "$bash_bin" ./scripts/end-user/jump-host-ssm.sh list "$@"
  echo "status=$status output=$output"
}

# macOS ships Bash 3.2; empty-array expansion under `set -u` is the list failure mode.
skip_unless_bash32() {
  if [[ ! -x /bin/bash ]]; then
    skip "/bin/bash not available"
  fi
  local major
  major="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')"
  if [[ "$major" -ge 4 ]]; then
    skip "/bin/bash is ${major}, not 3.2"
  fi
}

@test "list with no --tag and no instances succeeds on bash 3.2 with nounset" {
  skip_unless_bash32
  export FAKE_AWS_INSTANCES=empty
  run_list /bin/bash --region us-west-2
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No matching running jump hosts"* ]]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" != *"unary operator expected"* ]]
}

@test "list with no --tag and no instances succeeds" {
  export FAKE_AWS_INSTANCES=empty
  run_list bash --region us-west-2
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No matching running jump hosts (JumpHost=true)."* ]]
}

@test "list with --tag and no instances succeeds" {
  export FAKE_AWS_INSTANCES=empty
  run_list bash --region us-west-2 --tag Environment=stage
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"with given --tag filters"* ]]
}

@test "list prints matching instances" {
  export FAKE_AWS_INSTANCES=two
  run_list bash --region us-west-2
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"INSTANCE_ID"* ]]
  [[ "$output" == *"i-0123456789abcdef0"* ]]
  [[ "$output" == *"jump-core-01"* ]]
  [[ "$output" == *"i-0fedcba9876543210"* ]]
  [[ "$output" == *"jump-core-02"* ]]
}

@test "list --name-contains filters instance name tags" {
  export FAKE_AWS_INSTANCES=two
  run_list bash --region us-west-2 --name-contains core-02
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"i-0fedcba9876543210"* ]]
  [[ "$output" != *"i-0123456789abcdef0"* ]]
}

@test "list on bash 3.2 prints instances and accepts --tag" {
  skip_unless_bash32
  export FAKE_AWS_INSTANCES=one
  run_list /bin/bash --region us-west-2 --tag Environment=stage
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"i-0123456789abcdef0"* ]]
  [[ "$output" == *"jump-core-01"* ]]
}
