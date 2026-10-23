# CI and CD Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/orchestrate.sh` safe for offline CI (`validate`), read-only live CI (`plan`), and non-interactive CD (`apply`, `configure`, `destroy`) without hiding tool failures.

**Architecture:** `scripts/lib/run.sh` runs every external tool for the orchestrator and the SSM preflight script. `validate` stays offline. `plan` only reads and fails until observability, Session Manager preferences, and `log-transfer` outputs already exist. `apply` creates those prerequisites, then runs read-only preflight before the remaining stacks. `--non-interactive` and `--auto-approve` both skip the Terraform approval prompt; a non-terminal without either flag exits before Terraform.

**Tech Stack:** Bash 3.2, bats-core, Terraform, Terragrunt, Ansible, AWS CLI, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-10-23-ci-cd-orchestration-design.md`

## Global Constraints

- Bash 3.2 compatible. No namerefs, no associative arrays. Assign captured stdout with `printf -v`.
- `scripts/orchestrate.sh` and `scripts/preflight_ssm_compliance.sh` keep `set -euo pipefail` and source `scripts/lib/run.sh`.
- `run_logged` and `capture_stdout` print argv, leave stderr on the terminal, print `Error: command failed (exit N):` plus the argv, and exit with the tool status.
- `capture_stdout_status` captures without exiting. Preflight uses it, then prints the existing non-compliant line and exits 1.
- Never call `run_logged` or `capture_stdout` inside `$()`. `exit` in a command substitution only leaves the subshell.
- Tool calls in those two scripts do not use `2>/dev/null`, `|| true`, or a failure branch that continues the run.
- `SKIP_ACCOUNT_CHECK=true` prints `Skipping account identity check (SKIP_ACCOUNT_CHECK=true).` and continues.
- `SKIP_PREFLIGHT=true` prints `Skipping SSM preflight checks (SKIP_PREFLIGHT=true).` and continues.
- Script-detected problems exit 1. STS failures exit with the `aws` status via `capture_stdout`.
- `plan`, `init`, `apply`, `configure`, and `destroy` always pass `-input=false`.
- `--non-interactive` and `--auto-approve` both set non-interactive approval and pass `-auto-approve`.
- No terminal and neither flag: `apply`, `configure`, and `destroy` exit 1 before Terraform and name `--non-interactive`.
- `--ssm-self-management` is valid on `init`, `plan`, and `apply` only. `validate`, `configure`, and `destroy` exit 1 and name `init`, `plan`, and `apply`.
- `plan` and `configure` do not create the log group or Session Manager preferences.
- `apply` applies observability once, then `ssm-self-management` when flagged, then read-only preflight, then endpoints, jump hosts, `log-transfer`, and Ansible.
- Empty jump-host inventory exits `plan`, `apply`, and `configure`. `destroy` with zero hosts skips decommission and still destroys stacks.
- `check` exits 1 and points at `validate` and `plan`.
- Limitation text, copied wherever the spec requires it: `plan` and `configure` require an already-applied observability stack, compliant Session Manager preferences, the expected CloudWatch log group, and existing `log-transfer` outputs. A new account uses `apply` first. Use `apply --ssm-self-management` when this account must create the Session Manager preferences. `--ssm-self-management` on `plan` only adds a read-only plan of that stack.

---

## File structure

| Path | Responsibility |
| --- | --- |
| `scripts/lib/run.sh` | `log_argv`, `run_logged`, `capture_stdout`, `capture_stdout_status`. |
| `scripts/orchestrate.sh` | Commands, guards, banners, Terragrunt and Ansible sequencing. |
| `scripts/preflight_ssm_compliance.sh` | Read-only SSM checks. AWS failures keep stderr and still print the non-compliant line. |
| `tests/shell/run_lib.bats` | Runner status and stderr tests. |
| `tests/shell/orchestrate.bats` | Pipeline modes, guards, and updated existing cases. |
| `tests/shell/preflight_ssm_compliance.bats` | Preflight AWS failure and passing fixture. |
| `tests/shell/bin/terragrunt` | Existing fake, plus `hcl validate`. |
| `tests/shell/bin/terraform` | Fake `init` / `validate` for offline `validate` tests. |
| `tests/contracts/check_orchestration_limitation.sh` | Limitation text is present in help, README, and the consumer guide. |
| `Makefile` | `validate` calls the orchestrator. `lint` shellchecks `scripts/lib/*.sh`. `contract-test` runs the new check. |
| `README.md`, `docs/consumer-guide.md` | Command modes and the first-run limitation. |

---

### Task 1: Command runner

**Files:**
- Create: `scripts/lib/run.sh`
- Create: `tests/shell/run_lib.bats`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `log_argv command [args...]` prints a leading newline, `==> `, and `%q`-quoted argv
  - `run_logged command [args...]` runs the command in the current shell and exits with its status on failure
  - `capture_stdout varname command [args...]` stores stdout with `printf -v` and exits with the tool status on failure
  - `capture_stdout_status varname command [args...]` stores stdout and `return`s the tool status

- [ ] **Step 1: Write the failing test**

Create `tests/shell/run_lib.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/run_lib.bats`

Expected: FAIL because `scripts/lib/run.sh` does not exist.

- [ ] **Step 3: Write the runner**

Create `scripts/lib/run.sh`:

```bash
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
  "$@" && status=0 || status=$?
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
```

`capture_stdout` calls `capture_stdout_status`, which already printed argv. `report_command_failure` prints the error line. That is two `==>` lines only when `capture_stdout` is used (one from `capture_stdout_status`). Do not add a second `log_argv` in `capture_stdout`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/run_lib.bats`

Expected: PASS, 4 tests.

Run: `shellcheck scripts/lib/run.sh`

Expected: no findings.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/run.sh tests/shell/run_lib.bats
git commit -m "$(cat <<'EOF'
Add a command runner that preserves tool status and stderr.

EOF
)"
```

---

### Task 2: Preflight keeps AWS stderr

**Files:**
- Modify: `scripts/preflight_ssm_compliance.sh`
- Create: `tests/shell/preflight_ssm_compliance.bats`

**Interfaces:**
- Consumes: `capture_stdout_status varname command [args...]` from `scripts/lib/run.sh`
- Produces: unchanged CLI (`--region`, `--expected-log-group`, `--document-name`). AWS failures print stderr, then a `Non-compliant:` line, then exit 1. Success still prints `SSM preflight checks passed.`

- [ ] **Step 1: Write the failing test**

Create `tests/shell/preflight_ssm_compliance.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$REPO_ROOT" || exit 1
  FAKE_BIN="$(mktemp -d)"
  export PATH="${FAKE_BIN}:${PATH}"
}

teardown() {
  rm -rf "${FAKE_BIN:-}"
}

write_aws() {
  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ssm" && "${2:-}" == "get-document" ]]; then
  if [[ "${FAKE_AWS_DOCUMENT_FAIL:-}" == "1" ]]; then
    echo "document missing from aws" >&2
    exit 5
  fi
  cat <<'JSON'
{"inputs":{"runAsEnabled":true,"runAsDefaultUser":"ec2-user","cloudWatchLogGroupName":"/aws/ssm/jump-host/dev/east/us-east-1","cloudWatchStreamingEnabled":true,"cloudWatchEncryptionEnabled":false}}
JSON
  exit 0
fi
if [[ "${1:-}" == "ssm" && "${2:-}" == "get-service-setting" ]]; then
  echo "arn:aws:iam::111111111111:role/ssm-managed"
  exit 0
fi
if [[ "${1:-}" == "logs" && "${2:-}" == "describe-log-groups" ]]; then
  echo "1"
  exit 0
fi
echo "unhandled aws $*" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/aws"
}

@test "preflight document lookup failure shows aws stderr and the non-compliant line" {
  write_aws
  export FAKE_AWS_DOCUMENT_FAIL=1
  run ./scripts/preflight_ssm_compliance.sh \
    --region us-east-1 \
    --expected-log-group /aws/ssm/jump-host/dev/east/us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"document missing from aws"* ]]
  [[ "$output" == *"Non-compliant:"* ]]
  [[ "$output" == *"SSM-SessionManagerRunShell"* ]]
}

@test "preflight passes when the session document and log group match" {
  write_aws
  run ./scripts/preflight_ssm_compliance.sh \
    --region us-east-1 \
    --expected-log-group /aws/ssm/jump-host/dev/east/us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"SSM preflight checks passed."* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/preflight_ssm_compliance.bats`

Expected: the document-failure test FAILs because stderr is discarded with `2>/dev/null` and the output does not contain `document missing from aws`. The passing-fixture test may already pass.

- [ ] **Step 3: Stop hiding AWS stderr**

At the top of `scripts/preflight_ssm_compliance.sh`, after `set -euo pipefail`, add:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run.sh
source "${SCRIPT_DIR}/lib/run.sh"
```

Delete the `session_doc_content` and `default_host_management_role_setting` functions.

Replace the document lookup:

```bash
echo "Checking SSM Session Manager preferences in region: $region"

if ! capture_stdout_status document_content aws ssm get-document \
  --region "$region" \
  --name "$document_name" \
  --query 'Content' \
  --output text; then
  echo "Non-compliant: Session Manager preferences document '${document_name}' not found (create/update it or run with --ssm-self-management)" >&2
  exit 1
fi
```

Replace the service-setting lookup:

```bash
if ! capture_stdout_status default_host_role_setting aws ssm get-service-setting \
  --region "$region" \
  --setting-id "/ssm/managed-instance/default-ec2-instance-management-role" \
  --query 'ServiceSetting.SettingValue' \
  --output text; then
  echo "Non-compliant: could not read SSM service setting '/ssm/managed-instance/default-ec2-instance-management-role'" >&2
  exit 1
fi
```

Replace the log-group count lookup with:

```bash
if ! capture_stdout_status log_group_match_count aws logs describe-log-groups \
  --region "$region" \
  --log-group-name-prefix "$expected_log_group" \
  --query "length(logGroups[?logGroupName=='${expected_log_group}'])" \
  --output text; then
  echo "Non-compliant: could not query CloudWatch log group '${expected_log_group}'" >&2
  exit 1
fi
if [[ "${log_group_match_count:-0}" != "1" ]]; then
  echo "Non-compliant: CloudWatch log group '${expected_log_group}' not found (apply observability stack first)" >&2
  exit 1
fi
```

Replace the KMS lookup with:

```bash
if [[ "$cloudwatch_encryption_enabled" == "true" ]]; then
  if ! capture_stdout_status log_group_kms_key aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$expected_log_group" \
    --query "logGroups[?logGroupName=='${expected_log_group}'].kmsKeyId | [0]" \
    --output text; then
    echo "Non-compliant: could not query CloudWatch log group '${expected_log_group}'" >&2
    exit 1
  fi
  if [[ -z "$log_group_kms_key" || "$log_group_kms_key" == "None" ]]; then
    echo "Non-compliant: Session preferences require CloudWatch encryption, but log group '${expected_log_group}' has no kmsKeyId." >&2
    exit 1
  fi
fi
```

Leave the run-as, streaming, and log-group-name comparisons unchanged. Do not pass `2>/dev/null` to `aws`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/preflight_ssm_compliance.bats`

Expected: PASS, 2 tests.

Run: `shellcheck scripts/preflight_ssm_compliance.sh scripts/lib/run.sh`

Expected: no findings.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight_ssm_compliance.sh tests/shell/preflight_ssm_compliance.bats
git commit -m "$(cat <<'EOF'
Show AWS stderr when SSM preflight cannot read session settings.

EOF
)"
```

---

### Task 3: Account identity fails closed

**Files:**
- Modify: `scripts/orchestrate.sh` (`ensure_target_account_identity`)
- Modify: `tests/shell/orchestrate.bats`

**Interfaces:**
- Consumes: `capture_stdout varname command [args...]`
- Produces: `ensure_target_account_identity` exits 1 for a missing `aws` CLI, a missing `account.hcl`, or an unreadable `account_id`. STS failure exits with the `aws` status. A match prints `Account identity confirmed: <id>`. `SKIP_ACCOUNT_CHECK=true` prints the exact skip line and returns 0.

- [ ] **Step 1: Write the failing tests**

Append these tests to `tests/shell/orchestrate.bats`. Add this helper above the tests:

```bash
install_aws_stub() {
  FAKE_BIN="$(mktemp -d)"
  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_AWS_LOG:-}" ]]; then
  printf '%q ' "$@" >>"$FAKE_AWS_LOG"
  echo >>"$FAKE_AWS_LOG"
fi
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
  if [[ "${FAKE_AWS_STS_FAIL:-}" == "1" ]]; then
    echo "sts exploded" >&2
    exit 4
  fi
  echo "${FAKE_AWS_ACCOUNT:-111111111111}"
  exit 0
fi
if [[ "${1:-}" == "s3api" && "${2:-}" == "head-bucket" ]]; then
  exit 0
fi
echo "unhandled aws $*" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/aws"
  export PATH="${FAKE_BIN}:${PATH}"
}
```

`tests/shell/orchestrate.bats` has no `teardown` today. Add:

```bash
teardown() {
  if [[ -n "${FAKE_BIN:-}" ]]; then
    rm -rf "$FAKE_BIN"
  fi
}
```

Tests:

```bash
@test "orchestrate plan fails when account.hcl is missing" {
  install_aws_stub
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/dev/east/us-east-1"/{observability,vpc-endpoints,jump-hosts,log-transfer}
  run ./scripts/orchestrate.sh plan \
    --live-dir "$root" \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: account.hcl not found:"* ]]
  rm -rf "$root"
}

@test "orchestrate plan fails when account_id cannot be parsed" {
  install_aws_stub
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/dev/east/us-east-1"/{observability,vpc-endpoints,jump-hosts,log-transfer}
  printf 'locals {\n  account_id = "not-an-account"\n}\n' >"$root/dev/account.hcl"
  run ./scripts/orchestrate.sh plan \
    --live-dir "$root" \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: could not parse a 12-digit account_id from "* ]]
  rm -rf "$root"
}

@test "orchestrate plan preserves STS stderr and status" {
  install_aws_stub
  export FAKE_AWS_STS_FAIL=1
  export SKIP_PREFLIGHT=true
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"sts exploded"* ]]
  [[ "$output" == *"Error: command failed (exit 4):"* ]]
}

@test "orchestrate plan fails on account mismatch" {
  install_aws_stub
  export FAKE_AWS_ACCOUNT=999999999999
  export SKIP_PREFLIGHT=true
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: AWS account mismatch"* ]]
  [[ "$output" == *"999999999999"* ]]
  [[ "$output" == *"111111111111"* ]]
}

@test "orchestrate plan confirms a matching account" {
  install_aws_stub
  export FAKE_AWS_ACCOUNT=111111111111
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Account identity confirmed: 111111111111"* ]]
}

@test "SKIP_ACCOUNT_CHECK prints the skip line" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  run ./scripts/orchestrate.sh init \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Skipping account identity check (SKIP_ACCOUNT_CHECK=true)."* ]]
}
```

The matching-account test uses `hosts_ok`, so Ansible will call `head-bucket`. The stub above succeeds at that call. `examples/live/dev/account.hcl` contains `account_id = "111111111111"` and `state_bucket = "aws-jump-host-dev-state"`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/orchestrate.bats`

Expected: the new account tests FAIL. Missing `account.hcl` currently returns success from `ensure_target_account_identity`. STS failure is hidden and the run continues.

- [ ] **Step 3: Replace the account guard**

Source the runner in `scripts/orchestrate.sh` after `set -euo pipefail`:

```bash
# shellcheck source=lib/run.sh
source "${SCRIPT_DIR}/lib/run.sh"
```

`SCRIPT_DIR` is already set. Put the source line after that assignment.

Replace `ensure_target_account_identity` with:

```bash
ensure_target_account_identity() {
  if [[ "${SKIP_ACCOUNT_CHECK:-false}" == "true" ]]; then
    echo "Skipping account identity check (SKIP_ACCOUNT_CHECK=true)."
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: Missing required command: aws" >&2
    exit 1
  fi

  local account_hcl="${live_dir}/${env_name}/account.hcl"
  if [[ ! -f "$account_hcl" ]]; then
    echo "Error: account.hcl not found: ${account_hcl}" >&2
    exit 1
  fi

  local expected_account
  expected_account="$(sed -nE '/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"[0-9]{12}"/ {
    s/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"([0-9]{12})".*/\1/
    p
    q
  }' "$account_hcl")"
  if [[ -z "$expected_account" ]]; then
    echo "Error: could not parse a 12-digit account_id from ${account_hcl}" >&2
    exit 1
  fi

  local actual_account
  capture_stdout actual_account aws sts get-caller-identity --query Account --output text
  actual_account="$(printf '%s' "$actual_account" | tr -d '\n\r')"

  if [[ "$actual_account" != "$expected_account" ]]; then
    cat >&2 <<EOF
Error: AWS account mismatch for this live configuration.
  expected account_id: ${expected_account}
  active credentials: ${actual_account}

Export credentials/profile for account ${expected_account}, or set SKIP_ACCOUNT_CHECK=true to bypass this guard.
EOF
    exit 1
  fi

  echo "Account identity confirmed: ${actual_account}"
}
```

Do not pipe `sed` to `head`. Call `capture_stdout` in the current shell, not inside `$()`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/orchestrate.bats`

Expected: PASS, including the previous orchestrator tests. The matching-account `plan` still skips preflight and may warn about zero hosts only if `hosts_ok` is ignored. With `hosts_ok` the fake Terragrunt returns one host, and the AWS stub allows `head-bucket`.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh tests/shell/orchestrate.bats
git commit -m "$(cat <<'EOF'
Fail closed when the live AWS account cannot be proven.

EOF
)"
```

---

### Task 4: Non-interactive approval

**Files:**
- Modify: `scripts/orchestrate.sh`
- Modify: `tests/shell/orchestrate.bats`

**Interfaces:**
- Consumes: `run_logged`
- Produces:
  - `noninteractive=true` when `--non-interactive` or `--auto-approve` is set
  - `require_terminal_or_noninteractive` exits 1 when stdin is not a terminal and `noninteractive` is not `true`
  - `run_tg_apply` / `run_tg_destroy` always pass `-input=false`, and also pass `-auto-approve` when `noninteractive=true`
  - `log_run_banner` prints the startup banner before the account check

- [ ] **Step 1: Write the failing tests**

Append:

```bash
@test "apply without a terminal exits before terragrunt" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh apply \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--non-interactive"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}

@test "destroy without a terminal exits before terragrunt" {
  export SKIP_ACCOUNT_CHECK=true
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
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--non-interactive"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}

@test "non-interactive destroy passes -auto-approve and -input=false" {
  export SKIP_ACCOUNT_CHECK=true
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
    --non-interactive
  [[ "$status" -eq 0 ]]
  grep -q -- '-auto-approve' "$log"
  grep -q -- '-input=false' "$log"
  rm -f "$log"
}

@test "destroy on a terminal omits -auto-approve" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run python3 -c 'import os, pty, sys
status = pty.spawn(["./scripts/orchestrate.sh", "destroy", "--live-dir", "./examples/live", "--env", "dev", "--subenv", "east", "--region", "us-east-1"])
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(1)'
  [[ "$status" -eq 0 ]]
  grep -q 'destroy -input=false' "$log"
  run grep -qF -- '-auto-approve' "$log"
  [[ "$status" -ne 0 ]]
  rm -f "$log"
}
```

Replace the existing test `orchestrate destroy without --auto-approve does not add -auto-approve` with the two destroy tests above (no terminal, and terminal via `pty`). Keep `orchestrate destroy passes -auto-approve to terragrunt when --auto-approve set`, and extend its assertion so the log also contains `-input=false`.

Add `--non-interactive` to these existing `configure` invocations so they still reach their later assertions once a missing terminal is an error:

- `orchestrate configure fails when log-transfer outputs cannot be read`
- `orchestrate configure rejects an unsafe log-transfer bucket output`

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/orchestrate.bats`

Expected: `apply without a terminal` and `destroy without a terminal` FAIL because the fake Terragrunt exits 0 and the log is non-empty. `destroy on a terminal omits -auto-approve` FAIL because `-input=false` is not passed yet.

- [ ] **Step 3: Implement the approval gate**

Initialize `noninteractive="false"` next to `auto_approve="false"`.

Accept both flags:

```bash
    --auto-approve|--non-interactive)
      auto_approve="true"
      noninteractive="true"
      shift
      ;;
```

Add:

```bash
log_run_banner() {
  printf '\n==> orchestrate %s\n' "$command_name"
  if [[ "$command_name" == "validate" ]]; then
    printf '    mode: offline repository validation\n'
    printf '    non-interactive: %s\n' "$noninteractive"
    return 0
  fi
  printf '    live-dir: %s\n' "$live_dir"
  printf '    env/subenv/region: %s/%s/%s\n' "$env_name" "$subenv_name" "$aws_region"
  if [[ -n "$users_vars" ]]; then
    printf '    users-vars: %s\n' "$users_vars"
  else
    printf '    users-vars: (none)\n'
  fi
  printf '    non-interactive: %s\n' "$noninteractive"
  if [[ "${SKIP_ACCOUNT_CHECK:-false}" == "true" ]]; then
    printf '    account check: skipped (SKIP_ACCOUNT_CHECK=true)\n'
  else
    printf '    account check: required\n'
  fi
  case "$command_name" in
    plan|apply|configure)
      if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
        printf '    preflight: skipped (SKIP_PREFLIGHT=true)\n'
      else
        printf '    preflight: required\n'
      fi
      ;;
    *)
      printf '    preflight: not used\n'
      ;;
  esac
}

require_terminal_or_noninteractive() {
  if [[ "$noninteractive" == "true" ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    return 0
  fi
  cat >&2 <<EOF
Error: ${command_name} would prompt for Terraform approval, and stdin is not a terminal.
Re-run with --non-interactive for a CD pipeline.
EOF
  exit 1
}
```

Call `log_run_banner` once, after users-file validation and before the command `case`.

Replace `run_tg` so the Terragrunt invocation goes through `run_logged` in the current shell:

```bash
run_tg() {
  local stack_dir="$1"
  shift
  log_tg_action "$stack_dir" "$@"
  TG_DOWNLOAD_DIR="$TG_DOWNLOAD_DIR" TG_BACKEND_BOOTSTRAP=true \
    run_logged terragrunt --working-dir "$stack_dir" "$@"
}
```

Replace apply and destroy helpers:

```bash
run_tg_apply() {
  local stack_dir="$1"
  if [[ "$noninteractive" == "true" ]]; then
    run_tg "$stack_dir" apply -auto-approve -input=false
  else
    run_tg "$stack_dir" apply -input=false
  fi
}

run_tg_destroy() {
  local stack_dir="$1"
  if [[ "$noninteractive" == "true" ]]; then
    run_tg "$stack_dir" destroy -auto-approve -input=false
  else
    run_tg "$stack_dir" destroy -input=false
  fi
}
```

Pass `-input=false` on every existing `run_tg ... init` and `run_tg ... plan` call.

At the start of the `apply`, `configure`, and `destroy` arms, before any `run_tg*` call, call `require_terminal_or_noninteractive`. Account identity still runs first inside those arms, before the terminal check. The no-terminal tests set `SKIP_ACCOUNT_CHECK=true`, so they reach the terminal check with an empty Terragrunt log.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/orchestrate.bats`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh tests/shell/orchestrate.bats
git commit -m "$(cat <<'EOF'
Require a terminal or --non-interactive before Terraform approval.

EOF
)"
```

---

### Task 5: Empty inventory and log-transfer outputs fail closed

**Files:**
- Modify: `scripts/orchestrate.sh` (`run_ansible`, log-transfer output loading)
- Modify: `tests/shell/orchestrate.bats`

**Interfaces:**
- Consumes: `capture_stdout`, `run_logged`, `install_aws_stub`
- Produces: `load_log_transfer_outputs` sets `JUMP_HOST_LOG_TRANSFER_BUCKET` and `JUMP_HOST_LOG_TRANSFER_REGION` in the current shell, or exits. Empty inventory exits 1 for `plan`, `apply`, and `configure`. `destroy` with zero hosts prints `inventory has 0 jump hosts; skipping decommission.` and returns from `run_ansible` without calling `ansible-playbook`.

- [ ] **Step 1: Write the failing tests and update the old ones**

Rewrite `orchestrate plan skips log-transfer extra-vars when output lookup fails` so it expects failure. Use `hosts_ok`, `install_aws_stub`, `SKIP_ACCOUNT_CHECK=true`, `SKIP_PREFLIGHT=true`, and `FAKE_TG_OUTPUT_FAIL=1`:

```bash
@test "orchestrate plan fails when log-transfer outputs cannot be read" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  export FAKE_TG_OUTPUT_FAIL=1
  local ansible_log
  ansible_log="$(mktemp)"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"log-transfer"* ]]
  [[ "$output" == *"Error: command failed"* ]]
  [[ "$output" == *"unavailable"* ]]
  [[ ! -s "$ansible_log" ]]
  rm -f "$ansible_log"
}
```

Change these existing success cases from `FAKE_TG_SCENARIO=hosts_empty` to `hosts_ok`, and call `install_aws_stub` in each so `head-bucket` does not hit a real AWS account:

- `orchestrate plan runs log-transfer after jump-hosts`
- `orchestrate without --users-vars clears inherited JUMP_HOST_USERS_VARS`
- `orchestrate exports JUMP_HOST_USERS_VARS and JUMP_HOST_USERS_VALIDATOR`
- `orchestrate configure applies log-transfer before ansible`

`orchestrate configure fails when log-transfer outputs cannot be read` and `orchestrate configure rejects an unsafe log-transfer bucket output` also need `hosts_ok` and `install_aws_stub`. They already gain `--non-interactive` in Task 4.

Append:

```bash
@test "plan apply and configure fail when the inventory is empty" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local command_name
  for command_name in plan apply configure; do
    local log
    log="$(mktemp)"
    export FAKE_TG_LOG="$log"
    if [[ "$command_name" == "plan" ]]; then
      run ./scripts/orchestrate.sh "$command_name" \
        --live-dir ./examples/live \
        --env dev \
        --subenv east \
        --region us-east-1
    else
      run ./scripts/orchestrate.sh "$command_name" \
        --live-dir ./examples/live \
        --env dev \
        --subenv east \
        --region us-east-1 \
        --non-interactive
    fi
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"0 jump hosts"* ]]
    rm -f "$log"
  done
}

@test "destroy with zero hosts skips decommission and still destroys stacks" {
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_empty
  local log users
  log="$(mktemp)"
  users="$(mktemp)"
  printf 'users: []\n' >"$users"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --users-vars "$users" \
    --non-interactive
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"inventory has 0 jump hosts; skipping decommission."* ]]
  grep -q 'destroy -auto-approve' "$log"
  rm -f "$log" "$users"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/orchestrate.bats`

Expected: the rewritten plan output-lookup test FAILs because plan still exits 0 and sets `jump_host_log_transfer_skip=true`. The empty-inventory test FAILs because plan still exits 0.

- [ ] **Step 3: Fail closed in Ansible preparation**

Replace `resolve_log_transfer_outputs` with a current-shell loader:

```bash
load_log_transfer_outputs() {
  local bucket region
  capture_stdout bucket terragrunt --working-dir "$log_transfer_dir" output -raw bucket_name
  capture_stdout region terragrunt --working-dir "$log_transfer_dir" output -raw region
  bucket="$(printf '%s' "$bucket" | tr -d '\n\r')"
  region="$(printf '%s' "$region" | tr -d '\n\r')"
  if [[ -z "$bucket" || -z "$region" ]]; then
    echo "Error: log-transfer outputs bucket_name/region are empty in ${log_transfer_dir}." >&2
    exit 1
  fi
  if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    echo "Error: log-transfer output bucket_name is not a safe S3 bucket name." >&2
    exit 1
  fi
  if [[ ! "$region" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Error: log-transfer output region is not a safe AWS region id." >&2
    exit 1
  fi
  JUMP_HOST_LOG_TRANSFER_BUCKET="$bucket"
  JUMP_HOST_LOG_TRANSFER_REGION="$region"
}
```

In `run_ansible`, replace the `host_count -eq 0` warning with:

```bash
  if [[ "$host_count" -eq 0 ]]; then
    if [[ "$command_name" == "destroy" ]]; then
      printf '\n==> [ansible/%s] inventory has 0 jump hosts; skipping decommission.\n' "$playbook"
      return 0
    fi
    printf '\n==> [ansible/%s] Error: inventory has 0 jump hosts — refusing to continue.\n' "$playbook" >&2
    printf '    Fix: ensure Terraform apply created instances and terragrunt output '\''hosts'\'' is non-empty for %s\n' "$jump_hosts_dir" >&2
    exit 1
  fi
```

There is no remaining branch that skips the SSM bucket check for zero hosts on `plan`, `apply`, or `configure`.

Replace `check_ssm_transfer_bucket_access` with:

```bash
check_ssm_transfer_bucket_access() {
  local bucket="$1"
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: Missing required command: aws" >&2
    exit 1
  fi

  local head_output head_status=0
  capture_stdout_status head_output aws s3api head-bucket --bucket "$bucket" && head_status=0 || head_status=$?
  # Successful head-bucket output is empty. Reference it so the capture is intentional.
  : "$head_output"
  if [[ "$head_status" -ne 0 ]]; then
    cat >&2 <<EOF
Error: unable to access SSM transfer bucket '${bucket}' with current AWS credentials.

Ansible's amazon.aws.aws_ssm connection requires controller access to this bucket:
  - s3:ListBucket on arn:aws:s3:::${bucket}
  - s3:GetObject,s3:PutObject,s3:DeleteObject on arn:aws:s3:::${bucket}/*

Set a different bucket with ANSIBLE_AWS_SSM_BUCKET_NAME (or account.hcl local ansible_ssm_bucket),
or grant the current role access to this bucket.
EOF
    exit 1
  fi
}
```

Call `capture_stdout_status` in the current shell. AWS stderr stays on the terminal because the runner does not redirect it. The function then exits 1.

Replace the `log_xfer="$(resolve_log_transfer_outputs)"` block. For `jump_hosts.yml`, call `load_log_transfer_outputs` in the current shell, then append:

```bash
    extra+=(--extra-vars "jump_host_log_transfer_bucket=${JUMP_HOST_LOG_TRANSFER_BUCKET}")
    extra+=(--extra-vars "jump_host_log_transfer_region=${JUMP_HOST_LOG_TRANSFER_REGION}")
```

Delete the `jump_host_log_transfer_skip=true` branch.

Keep the existing "no --users-vars" destroy message: `Skipping Ansible decommission hooks (no --users-vars provided).` Destroy calls `run_ansible` only when `--users-vars` is set.

Run these in the current shell through `run_logged`:

```bash
  run_logged "${SCRIPT_DIR}/render_inventory.sh" \
    --terragrunt-dir "$jump_hosts_dir" \
    --output "$inventory_path"
```

The second `render_inventory.sh` call, after the bucket check, uses the same `run_logged` form and keeps its existing `--connection`, `--ssm-region`, `--ssm-bucket`, and `--s3-addressing-style` arguments.

```bash
  run_logged ansible-galaxy collection install \
    -r "${REPO_ROOT}/ansible/requirements.yml" \
    -p "${REPO_ROOT}/ansible/collections"
```

```bash
  run_logged ansible-playbook \
    -i "$inventory_path" \
    "${REPO_ROOT}/ansible/playbooks/${playbook}" \
    "${extra[@]}"
```

Keep the existing `ANSIBLE_CONFIG`, `AWS_REGION`, and `OBJC_DISABLE_INITIALIZE_FORK_SAFETY` assignments on the `ansible-playbook` invocation. A prefix assignment before `run_logged` applies to the function and to `ansible-playbook`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/orchestrate.bats`

Expected: PASS. `rg jump_host_log_transfer_skip scripts/orchestrate.sh` prints no matches.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh tests/shell/orchestrate.bats
git commit -m "$(cat <<'EOF'
Fail closed on an empty inventory or unreadable log-transfer outputs.

EOF
)"
```

---

### Task 6: Read-only plan and ordered apply

**Files:**
- Modify: `scripts/orchestrate.sh` (`run_preflight`, command `case`)
- Modify: `tests/shell/orchestrate.bats` (`install_aws_stub`)

**Interfaces:**
- Consumes: `run_logged`, `run_tg`, `run_tg_apply`, `require_terminal_or_noninteractive`, `install_aws_stub`
- Produces: `run_preflight` only reads. `plan` never runs `terragrunt apply`. `apply` applies observability once before preflight. `configure` applies only `log-transfer`.

- [ ] **Step 1: Extend the AWS stub and write the failing tests**

Replace `install_aws_stub` with a version that also serves preflight. Keep the STS and `head-bucket` behavior from Task 3. Add:

```bash
if [[ "${1:-}" == "ssm" && "${2:-}" == "get-document" ]]; then
  if [[ "${FAKE_AWS_DOCUMENT_FAIL:-}" == "1" ]]; then
    echo "document missing from aws" >&2
    exit 5
  fi
  cat <<'JSON'
{"inputs":{"runAsEnabled":true,"runAsDefaultUser":"ec2-user","cloudWatchLogGroupName":"/aws/ssm/jump-host/dev/east/us-east-1","cloudWatchStreamingEnabled":true,"cloudWatchEncryptionEnabled":false}}
JSON
  exit 0
fi
if [[ "${1:-}" == "ssm" && "${2:-}" == "get-service-setting" ]]; then
  echo "arn:aws:iam::111111111111:role/ssm-managed"
  exit 0
fi
if [[ "${1:-}" == "logs" && "${2:-}" == "describe-log-groups" ]]; then
  echo "1"
  exit 0
fi
```

The expected log group in that JSON matches `dev/east/us-east-1`, which is what `plan` computes for the example live directory.

Append:

```bash
@test "plan does not apply stacks" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --ssm-self-management
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert "ssm-self-management" in text, text
assert "plan" in text, text
for line in text.splitlines():
    assert "apply" not in line.split(), line
' "$log"
  [[ "$output" == *"does not create the CloudWatch log group"* ]]
  rm -f "$log"
}

@test "plan stops before terragrunt when preflight cannot read the session document" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_AWS_DOCUMENT_FAIL=1
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"document missing from aws"* ]]
  [[ "$output" == *"plan does not create the CloudWatch log group"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}

@test "apply runs observability before the other stacks" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh apply \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive \
    --ssm-self-management
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
lines = [line for line in text.splitlines() if "apply" in line.split()]
joined = "\n".join(lines)
obs = joined.find("observability")
ssm = joined.find("ssm-self-management")
ep = joined.find("vpc-endpoints")
jump = joined.find("jump-hosts")
log_transfer = joined.find("log-transfer")
assert -1 not in (obs, ssm, ep, jump, log_transfer), joined
assert obs < ssm < ep < jump < log_transfer, joined
assert joined.count("observability") == 1, joined
' "$log"
  grep -q -- '-auto-approve' "$log"
  grep -q -- '-input=false' "$log"
  rm -f "$log"
}

@test "configure applies log-transfer and not observability" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export FAKE_TG_SCENARIO=hosts_ok
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert "log-transfer" in text, text
assert "observability" not in text, text
for line in text.splitlines():
    parts = line.split()
    if "apply" in parts:
        assert "log-transfer" in line, line
' "$log"
  rm -f "$log"
}

@test "configure rejects --ssm-self-management" {
  run ./scripts/orchestrate.sh configure \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive \
    --ssm-self-management
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--ssm-self-management"* ]]
  [[ "$output" == *"init, plan, or apply"* ]]
}

@test "destroy rejects --ssm-self-management" {
  run ./scripts/orchestrate.sh destroy \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1 \
    --non-interactive \
    --ssm-self-management
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"init, plan, or apply"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/orchestrate.bats`

Expected: `plan does not apply stacks` FAILs because preflight still runs `terragrunt apply` for observability. `configure applies log-transfer and not observability` FAILs for the same reason.

- [ ] **Step 3: Make preflight read-only and reorder apply**

Delete `run_tg_apply_preflight`.

Replace `run_preflight`:

```bash
run_preflight() {
  if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
    echo "Skipping SSM preflight checks (SKIP_PREFLIGHT=true)."
    return 0
  fi

  case "$command_name" in
    plan|configure)
      echo "SSM preflight is read-only. ${command_name} does not create the CloudWatch log group or Session Manager preferences."
      ;;
    apply)
      if [[ "$ssm_self_management" == "true" ]]; then
        echo "SSM preflight is read-only. Applied stacks: observability, ssm-self-management. Endpoints, jump hosts, log-transfer, and Ansible run only after this check passes."
      else
        echo "SSM preflight is read-only. Applied stacks: observability. Endpoints, jump hosts, log-transfer, and Ansible run only after this check passes."
      fi
      ;;
  esac

  run_logged "${SCRIPT_DIR}/preflight_ssm_compliance.sh" \
    --region "$aws_region" \
    --expected-log-group "$expected_log_group"
}
```

After argument parsing, before required-directory checks:

```bash
case "$command_name" in
  validate|configure|destroy)
    if [[ "$ssm_self_management" == "true" ]]; then
      echo "Error: --ssm-self-management is not valid with ${command_name}. Use it with init, plan, or apply." >&2
      exit 1
    fi
    ;;
esac
```

`validate` does not exist until Task 7. Including it in this `case` now is safe: an unknown command still falls through to the existing unsupported-command error if someone runs `validate` before Task 7. This task's configure test is the one that must pass.

Replace the `plan`, `apply`, and `configure` arms:

```bash
  plan)
    ensure_target_account_identity
    run_preflight
    run_tg "$observability_dir" plan -input=false
    if [[ "$ssm_self_management" == "true" ]]; then
      run_tg "$ssm_self_management_dir" plan -input=false
    fi
    run_tg "$endpoints_dir" plan -input=false
    run_tg "$jump_hosts_dir" plan -input=false
    run_tg "$log_transfer_dir" plan -input=false
    run_ansible "jump_hosts.yml" "true"
    ;;

  apply)
    ensure_target_account_identity
    require_terminal_or_noninteractive
    run_tg_apply "$observability_dir"
    if [[ "$ssm_self_management" == "true" ]]; then
      run_tg_apply "$ssm_self_management_dir"
    fi
    run_preflight
    run_tg_apply "$endpoints_dir"
    run_tg_apply "$jump_hosts_dir"
    run_tg_apply "$log_transfer_dir"
    run_ansible "jump_hosts.yml"
    ;;

  configure)
    ensure_target_account_identity
    require_terminal_or_noninteractive
    run_preflight
    run_tg_apply "$log_transfer_dir"
    run_ansible "jump_hosts.yml"
    ;;
```

`init` still inits every stack, including `ssm-self-management` when the flag is set, and passes `-input=false`. It does not call `require_terminal_or_noninteractive` or `run_preflight`.

Do not apply observability a second time inside `apply`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/orchestrate.bats tests/shell/preflight_ssm_compliance.bats`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh tests/shell/orchestrate.bats
git commit -m "$(cat <<'EOF'
Keep plan and configure read-only until apply creates prerequisites.

EOF
)"
```

---

### Task 7: Offline validate and retired check

**Files:**
- Modify: `scripts/orchestrate.sh`
- Modify: `tests/shell/bin/terragrunt`
- Create: `tests/shell/bin/terraform`
- Modify: `tests/shell/orchestrate.bats`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `run_logged`, `log_run_banner`
- Produces: `orchestrate.sh validate` with no required target flags. `orchestrate.sh check` exits 1. `make validate` calls `./scripts/orchestrate.sh validate`. `make lint` shellchecks `scripts/lib/*.sh`.

- [ ] **Step 1: Write the failing tests**

Create `tests/shell/bin/terraform`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${FAKE_TERRAFORM_LOG:-}" ]]; then
  printf '%q ' "$@" >>"$FAKE_TERRAFORM_LOG"
  echo >>"$FAKE_TERRAFORM_LOG"
fi

if [[ "${FAKE_TERRAFORM_FAIL:-}" == "1" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == "validate" ]]; then
      echo "terraform validate exploded" >&2
      exit 2
    fi
  done
fi

exit 0
```

`chmod +x tests/shell/bin/terraform`. The shared bats helper already prepends `tests/shell/bin` to `PATH`.

In `tests/shell/bin/terragrunt`, before the final `fake terragrunt: unhandled` line, accept HCL validate:

```bash
if [[ "${1:-}" == "hcl" && "${2:-}" == "validate" ]]; then
  exit 0
fi
```

Append orchestrator tests:

```bash
@test "validate runs terraform, terragrunt hcl validate, and ansible syntax-check" {
  local tf_log tg_log ansible_log
  tf_log="$(mktemp)"
  tg_log="$(mktemp)"
  ansible_log="$(mktemp)"
  export FAKE_TERRAFORM_LOG="$tf_log"
  export FAKE_TG_LOG="$tg_log"
  export FAKE_ANSIBLE_LOG="$ansible_log"
  run ./scripts/orchestrate.sh validate
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"offline repository validation"* ]]
  grep -q 'validate' "$tf_log"
  grep -q 'hcl' "$tg_log"
  grep -q -- '--syntax-check' "$ansible_log"
  [[ "$(grep -c -- '--syntax-check' "$ansible_log")" -eq 2 ]]
  rm -f "$tf_log" "$tg_log" "$ansible_log"
}

@test "validate stops at the first failing terraform validate" {
  local tf_log tg_log
  tf_log="$(mktemp)"
  tg_log="$(mktemp)"
  export FAKE_TERRAFORM_LOG="$tf_log"
  export FAKE_TG_LOG="$tg_log"
  export FAKE_TERRAFORM_FAIL=1
  run ./scripts/orchestrate.sh validate
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"terraform validate exploded"* ]]
  [[ "$output" == *"Error: command failed (exit 2):"* ]]
  [[ "$(grep -c validate "$tf_log")" -eq 1 ]]
  [[ ! -s "$tg_log" ]]
  rm -f "$tf_log" "$tg_log"
}

@test "validate rejects --ssm-self-management" {
  run ./scripts/orchestrate.sh validate --ssm-self-management
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--ssm-self-management"* ]]
  [[ "$output" == *"init, plan, or apply"* ]]
  [[ "$output" != *"offline repository validation"* ]]
}

@test "check names validate and plan and does not run terragrunt" {
  local log
  log="$(mktemp)"
  export FAKE_TG_LOG="$log"
  run ./scripts/orchestrate.sh check
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"validate"* ]]
  [[ "$output" == *"plan"* ]]
  [[ ! -s "$log" ]]
  rm -f "$log"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shell/orchestrate.bats --filter 'validate|check names'`

Expected: FAIL because `validate` and the retired `check` message do not exist. The current `check` arm tries to run linters.

- [ ] **Step 3: Add validate and retire check**

Immediately after `command_name` is set and its arguments are parsed, before the live-directory requirement:

```bash
if [[ "$command_name" == "check" ]]; then
  cat >&2 <<EOF
Error: 'check' no longer runs from orchestrate.sh.
Offline CI: $0 validate
Read-only live CI: $0 plan --live-dir <path> --env <env> --subenv <subenv> --region <region>
Formatting and lint: make fmt-check && make lint
EOF
  exit 1
fi
```

Skip the live-dir, env, subenv, and region requirement when `command_name` is `validate`. Skip the required-directory loop for `validate`. Still run users-file validation when `--users-vars` is present. `validate` does not call `ensure_target_account_identity`.

Add this arm:

```bash
  validate)
    echo "validate: terraform validate for modules/terraform, terragrunt hcl validate for examples/live, ansible syntax-check for both playbooks."
    require_cmd terraform
    require_cmd terragrunt
    require_cmd ansible-playbook
    local_module=""
    local_stack=""
    for local_module in "${REPO_ROOT}"/modules/terraform/*; do
      [[ -d "$local_module" ]] || continue
      echo "validate: terraform validate ${local_module#"${REPO_ROOT}"/}"
      run_logged terraform -chdir="$local_module" init -backend=false -input=false -no-color
      run_logged terraform -chdir="$local_module" validate -no-color
    done
    while IFS= read -r local_stack; do
      [[ -n "$local_stack" ]] || continue
      echo "validate: terragrunt hcl validate ${local_stack#"${REPO_ROOT}"/}"
      TG_DOWNLOAD_DIR="$TG_DOWNLOAD_DIR" run_logged terragrunt hcl validate --inputs --working-dir "$local_stack"
    done < <(find "${REPO_ROOT}/examples/live" \
      -type d -name .terragrunt-cache -prune -o \
      -type d -name .terraform -prune -o \
      -type f -name terragrunt.hcl -exec dirname {} \; | sort)
    run_logged ansible-playbook \
      -i "${REPO_ROOT}/ansible/inventory/hosts.yml" \
      "${REPO_ROOT}/ansible/playbooks/jump_hosts.yml" \
      --syntax-check
    run_logged ansible-playbook \
      -i "${REPO_ROOT}/ansible/inventory/hosts.yml" \
      "${REPO_ROOT}/ansible/playbooks/decommission.yml" \
      --syntax-check
    ;;
```

`log_run_banner` already handles `validate`. It must run for `validate` too, after the users-file block and before the command `case`.

Delete the old `check)` arm that runs formatters, linters, and preflight.

In the `Makefile`, replace the `validate` recipe with:

```make
validate: install-tools
	TG_DOWNLOAD_DIR="$(TG_DOWNLOAD_DIR)" ./scripts/orchestrate.sh validate
```

Change the `shellcheck` line in `lint` to:

```make
	shellcheck scripts/*.sh scripts/lib/*.sh
```

Update the `help` line for `validate` so it says the target runs `scripts/orchestrate.sh validate`.

Add `validate` to the orchestrator `usage` synopsis. The full limitation paragraph is added in Task 8. This task's usage line must name `validate` and say it does not take a live target:

```text
  $0 validate
  $0 <init|plan|apply|configure|destroy> --live-dir <path> --env <env> --subenv <subenv> --region <region> [--users-vars <path>] [--non-interactive|--auto-approve] [--ssm-self-management]
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/shell/orchestrate.bats tests/shell/run_lib.bats tests/shell/preflight_ssm_compliance.bats`

Expected: PASS.

Run: `shellcheck scripts/orchestrate.sh scripts/lib/run.sh scripts/preflight_ssm_compliance.sh tests/shell/bin/terraform tests/shell/bin/terragrunt`

Expected: no findings.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh tests/shell/orchestrate.bats tests/shell/bin/terragrunt tests/shell/bin/terraform Makefile
git commit -m "$(cat <<'EOF'
Add offline validate and retire the mutating check command.

EOF
)"
```

---

### Task 8: Document the first-run limitation

**Files:**
- Modify: `scripts/orchestrate.sh` (`usage`)
- Modify: `README.md`
- Modify: `docs/consumer-guide.md`
- Modify: `tests/shell/orchestrate.bats`
- Create: `tests/contracts/check_orchestration_limitation.sh`
- Modify: `Makefile` (`contract-test`)

**Interfaces:**
- Consumes: the limitation paragraph in Global Constraints
- Produces: that paragraph in orchestrator help, `README.md`, and `docs/consumer-guide.md`

- [ ] **Step 1: Write the failing contract**

Create `tests/contracts/check_orchestration_limitation.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "contract check failed: $*" >&2; exit 1; }

phrase="plan and configure require an already-applied observability stack, compliant Session Manager preferences, the expected CloudWatch log group, and existing log-transfer outputs. A new account uses apply first."

for file in \
  "$root/scripts/orchestrate.sh" \
  "$root/README.md" \
  "$root/docs/consumer-guide.md"
do
  if ! grep -F -q "$phrase" "$file"; then
    fail "missing first-run limitation in ${file#"$root"/}"
  fi
done

echo "orchestration limitation contract OK"
```

`chmod +x tests/contracts/check_orchestration_limitation.sh`

Add it to the `contract-test` recipe in the `Makefile`, after `check_deprecated_vars.sh`:

```make
	./tests/contracts/check_orchestration_limitation.sh
```

- [ ] **Step 2: Run the contract to verify it fails**

Run: `./tests/contracts/check_orchestration_limitation.sh`

Expected: FAIL with `missing first-run limitation in scripts/orchestrate.sh`.

- [ ] **Step 3: Write the docs**

Put this paragraph in the `usage` heredoc of `scripts/orchestrate.sh`, in the Example Orchestration section of `README.md`, and in the configure/teardown section of `docs/consumer-guide.md`:

```text
plan and configure require an already-applied observability stack, compliant Session Manager preferences, the expected CloudWatch log group, and existing log-transfer outputs. A new account uses apply first. Use apply --ssm-self-management when this account must create the Session Manager preferences. --ssm-self-management on plan only adds a read-only plan of that stack.
```

In `README.md`, state that `apply`, `configure`, and `destroy` prompt on a terminal, and that CD passes `--non-interactive`. State that `make validate` runs `./scripts/orchestrate.sh validate`.

In `docs/consumer-guide.md`, replace the sentence that says non-interactive CI should append `--auto-approve` to `apply` and `destroy`. Say CD passes `--non-interactive` to `apply`, `configure`, and `destroy`, and that `--auto-approve` remains an equivalent approval flag. Replace the sentence that says `plan` leaves existing host files unchanged when log-transfer outputs are unavailable. Say `plan`, `apply`, and `configure` exit before Ansible when those outputs are missing, empty, or unsafe.

Keep the backticks and markdown links already used in those files around the rest of the section. The contract phrase itself must appear as one physical line, with no backticks splitting `plan and configure` or `apply first`.

Add this regression test to `tests/shell/orchestrate.bats`. It calls `plan` with preflight skipped, so the assertion is on the line `run_preflight` prints:

```bash
@test "SKIP_PREFLIGHT prints the skip line" {
  install_aws_stub
  export SKIP_ACCOUNT_CHECK=true
  export SKIP_PREFLIGHT=true
  export FAKE_TG_SCENARIO=hosts_ok
  run ./scripts/orchestrate.sh plan \
    --live-dir ./examples/live \
    --env dev \
    --subenv east \
    --region us-east-1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Skipping SSM preflight checks (SKIP_PREFLIGHT=true)."* ]]
}
```

- [ ] **Step 4: Run the contract to verify it passes**

Run: `./tests/contracts/check_orchestration_limitation.sh`

Expected: `orchestration limitation contract OK`

Run: `bats tests/shell/orchestrate.bats tests/shell/preflight_ssm_compliance.bats tests/shell/run_lib.bats`

Expected: PASS.

Run: `shellcheck scripts/orchestrate.sh scripts/lib/run.sh scripts/preflight_ssm_compliance.sh`

Expected: no findings.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh README.md docs/consumer-guide.md tests/shell/orchestrate.bats tests/contracts/check_orchestration_limitation.sh Makefile
git commit -m "$(cat <<'EOF'
Document that plan and configure require an existing observability stack.

EOF
)"
```
