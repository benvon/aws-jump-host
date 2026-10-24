#!/usr/bin/env bash
# Tool runner for orchestrate.sh and preflight_ssm_compliance.sh.
# Callers must already have set -euo pipefail.
# Do not call run_logged or capture_stdout from inside $().

log_argv() {
  printf '\n==> '
  printf '%q ' "$@"
  printf '\n'
}

report_command_failure() {
  local status="$1"
  shift
  printf 'Error: command failed (exit %s): ' "$status" >&2
  printf '%q ' "$@" >&2
  printf '\n' >&2
}

run_logged() {
  log_argv "$@"
  local status=0
  ( "$@" ) && status=0 || status=$?
  if [[ "$status" -ne 0 ]]; then
    report_command_failure "$status" "$@"
    exit "$status"
  fi
}

capture_stdout_status() {
  local __name="$1"
  shift
  local __output __status=0
  log_argv "$@"
  __output="$("$@")" && __status=0 || __status=$?
  printf -v "$__name" '%s' "$__output"
  return "$__status"
}

capture_stdout() {
  local __name="$1"
  shift
  local __status=0
  capture_stdout_status "$__name" "$@" && __status=0 || __status=$?
  if [[ "$__status" -ne 0 ]]; then
    report_command_failure "$__status" "$@"
    exit "$__status"
  fi
}
