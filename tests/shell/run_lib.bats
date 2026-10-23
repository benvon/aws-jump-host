#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$REPO_ROOT" || exit 1
}

@test "run_logged keeps stderr and exits with the tool status" {
  run bash -c '
    set -euo pipefail
    source scripts/lib/run.sh
    fail() { echo "tool blew up" >&2; exit 7; }
    run_logged fail
  '
  [[ "$status" -eq 7 ]]
  [[ "$output" == *"tool blew up"* ]]
  [[ "$output" == *"Error: command failed (exit 7):"* ]]
  [[ "$output" == *"==>"* ]]
}

@test "capture_stdout stores stdout and exits with the tool status" {
  run bash -c '
    set -euo pipefail
    source scripts/lib/run.sh
    boom() { echo "partial"; echo "nope" >&2; exit 3; }
    capture_stdout got boom
    echo "stored=$got"
  '
  [[ "$status" -eq 3 ]]
  [[ "$output" == *"nope"* ]]
  [[ "$output" == *"Error: command failed (exit 3):"* ]]
  [[ "$output" != *"stored="* ]]
}

@test "capture_stdout_status returns failure without exiting the shell" {
  run bash -c '
    set -euo pipefail
    source scripts/lib/run.sh
    boom() { echo "partial"; echo "nope" >&2; exit 3; }
    if capture_stdout_status got boom; then
      echo "should-not-succeed"
    else
      echo "failed"
      printf "got=%s\n" "$got"
    fi
  '
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"nope"* ]]
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"got=partial"* ]]
  [[ "$output" != *"should-not-succeed"* ]]
}

@test "capture_stdout stores a successful command" {
  run bash -c '
    set -euo pipefail
    source scripts/lib/run.sh
    say() { echo "hello"; }
    capture_stdout got say
    printf "got=%s\n" "$got"
  '
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"got=hello"* ]]
}
