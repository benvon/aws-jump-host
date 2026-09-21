# awslogin Session Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under shared Linux user `ec2-user`, isolate SSO credentials per Session Manager shell so concurrent sessions cannot reuse each other’s tokens after `awslogin`.

**Architecture:** `profile.d` creates a session AWS home under `$HOME/.cache/jump-host-aws/<id>/` for `ec2-user` only, exports `JUMP_HOST_AWS_HOME` / `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE`, and registers a best-effort EXIT trap. `awslogin` runs `sso login` with `HOME=$JUMP_HOST_AWS_HOME`, exports short-lived keys into the session credentials file, and strips `sso_*` from the session config copy (never the durable `~/.aws/config`).

**Tech Stack:** Bash 3.2, Ansible `session_comfort`, bats-core, AWS CLI v2 (`sso login`, `configure export-credentials --format process`).

**Spec:** `docs/superpowers/specs/2026-09-21-awslogin-session-isolation-design.md`  
**Issue:** https://github.com/benvon/aws-jump-host/issues/20

## Global Constraints

- Shared-user only: isolation when `id -un` equals `ec2-user`; no-op for other users.
- Session dir: `$HOME/.cache/jump-host-aws/<session-id>/` mode `0700`, with `.aws/config`, `.aws/credentials`, `.aws/sso/cache/`.
- Env exports (do not change Linux `$HOME`): `JUMP_HOST_AWS_HOME`, `JUMP_HOST_AWS_SESSION_ID`, `AWS_CONFIG_FILE=$JUMP_HOST_AWS_HOME/.aws/config`, `AWS_SHARED_CREDENTIALS_FILE=$JUMP_HOST_AWS_HOME/.aws/credentials`.
- EXIT trap: best-effort `rm -rf` only if path is under `$HOME/.cache/jump-host-aws/`.
- `awslogin` without `JUMP_HOST_AWS_HOME`: unchanged `aws sso login --profile … --no-browser --use-device-code`.
- `awslogin` with session env: `HOME=$JUMP_HOST_AWS_HOME` for login + export-credentials; write credentials INI; strip `sso_*` from **session** config only; never modify durable `$HOME/.aws/config`.
- Bash 3.2 compatible; no associative arrays.
- Prefer per-user Run As in docs; this is the shared-user mitigation.
- Do not change IMDS / instance-role policy.

---

## File structure

| Path | Responsibility |
| --- | --- |
| `ansible/roles/session_comfort/files/jump-host-aws-session.sh` | `profile.d` script: shared-user session dir, env, trap. |
| `ansible/roles/session_comfort/tasks/main.yml` | Install the snippet to `/etc/profile.d/jump-host-aws-session.sh`. |
| `ansible/roles/session_comfort/files/awslogin` | Login + optional session credential materialization. |
| `tests/shell/awslogin-session.bats` | Tests for profile.d script + session-aware `awslogin`. |
| `tests/shell/awslogin-kubelogin.bats` | Keep existing non-session `awslogin`/`kubelogin` tests green. |
| `docs/jump-host-end-user-guide.md` | Document isolation; retire “known gap / #20” warning. |
| `docs/access-model.md` | Describe implemented shared-user isolation. |

---

### Task 1: `profile.d` session script (TDD)

**Files:**
- Create: `ansible/roles/session_comfort/files/jump-host-aws-session.sh`
- Create: `tests/shell/awslogin-session.bats` (profile.d cases first)
- Modify: `ansible/roles/session_comfort/tasks/main.yml` (install snippet)

**Interfaces:**
- Consumes: Linux username via `id -un`; durable `$HOME/.aws/config` if present
- Produces: env `JUMP_HOST_AWS_HOME`, `JUMP_HOST_AWS_SESSION_ID`, `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`; EXIT trap

- [ ] **Step 1: Write failing bats for profile.d shared vs non-shared**

Create `tests/shell/awslogin-session.bats` with at least:

```bash
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

@test "profile.d is a no-op for non-shared users" {
  install_id_stub alice
  # shellcheck disable=SC1090
  source "$SESSION_SH"
  [[ -z "${JUMP_HOST_AWS_HOME:-}" ]]
  [[ -z "${AWS_CONFIG_FILE:-}" ]]
  [[ -z "${AWS_SHARED_CREDENTIALS_FILE:-}" ]]
  ! [[ -d "$HOME_DIR/.cache/jump-host-aws" ]] || [[ -z "$(find "$HOME_DIR/.cache/jump-host-aws" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]
}

@test "profile.d creates session AWS home and exports for ec2-user" {
  install_id_stub ec2-user
  # shellcheck disable=SC1090
  source "$SESSION_SH"
  [[ -n "${JUMP_HOST_AWS_HOME:-}" ]]
  [[ -n "${JUMP_HOST_AWS_SESSION_ID:-}" ]]
  [[ "$AWS_CONFIG_FILE" == "$JUMP_HOST_AWS_HOME/.aws/config" ]]
  [[ "$AWS_SHARED_CREDENTIALS_FILE" == "$JUMP_HOST_AWS_HOME/.aws/credentials" ]]
  [[ -f "$AWS_CONFIG_FILE" ]]
  grep -q 'sso_start_url' "$AWS_CONFIG_FILE"
  [[ "$(stat -f '%Lp' "$JUMP_HOST_AWS_HOME" 2>/dev/null || stat -c '%a' "$JUMP_HOST_AWS_HOME")" == *"700"* ]] || [[ "$(stat -c '%a' "$JUMP_HOST_AWS_HOME")" == "700" ]]
}

@test "profile.d EXIT trap removes the session directory for ec2-user" {
  install_id_stub ec2-user
  bash -c '
    set -euo pipefail
    source "$1"
    test -d "$JUMP_HOST_AWS_HOME"
    marker="$JUMP_HOST_AWS_HOME"
    echo "$marker" > /tmp/jh-aws-marker.$$
  ' bash "$SESSION_SH"
  marker="$(cat /tmp/jh-aws-marker.$$)"
  rm -f /tmp/jh-aws-marker.$$
  ! [[ -d "$marker" ]]
}
```

Adjust the mode assertion for macOS (`stat -f '%Lp'`) vs Linux (`stat -c '%a'`) in one portable check.

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/shell/awslogin-session.bats
```

Expected: FAIL (missing `jump-host-aws-session.sh` or empty behavior).

- [ ] **Step 3: Implement `jump-host-aws-session.sh`**

Create `ansible/roles/session_comfort/files/jump-host-aws-session.sh`:

```bash
# Jump-host AWS session isolation for shared Run As users (ec2-user).
# Installed as /etc/profile.d/jump-host-aws-session.sh
# shellcheck shell=bash

# Only interactive shells; avoid breaking scp/non-interactive.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

_jh_aws_user="$(id -un 2>/dev/null || true)"
if [[ "$_jh_aws_user" != ec2-user ]]; then
  unset _jh_aws_user
  return 0 2>/dev/null || exit 0
fi
unset _jh_aws_user

# Already initialized in this shell (nested source).
if [[ -n "${JUMP_HOST_AWS_HOME:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -z "${HOME:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_jh_aws_root="${HOME}/.cache/jump-host-aws"
mkdir -p "$_jh_aws_root"
# Session id: prefer uuidgen, else od from /dev/urandom.
if command -v uuidgen >/dev/null 2>&1; then
  JUMP_HOST_AWS_SESSION_ID="$(uuidgen | tr 'A-F' 'a-f')"
else
  JUMP_HOST_AWS_SESSION_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
fi
export JUMP_HOST_AWS_SESSION_ID
JUMP_HOST_AWS_HOME="${_jh_aws_root}/${JUMP_HOST_AWS_SESSION_ID}"
export JUMP_HOST_AWS_HOME
mkdir -m 700 -p "${JUMP_HOST_AWS_HOME}/.aws/sso/cache"

if [[ -r "${HOME}/.aws/config" ]]; then
  cp "${HOME}/.aws/config" "${JUMP_HOST_AWS_HOME}/.aws/config"
  chmod 600 "${JUMP_HOST_AWS_HOME}/.aws/config"
else
  : >"${JUMP_HOST_AWS_HOME}/.aws/config"
  chmod 600 "${JUMP_HOST_AWS_HOME}/.aws/config"
fi
: >"${JUMP_HOST_AWS_HOME}/.aws/credentials"
chmod 600 "${JUMP_HOST_AWS_HOME}/.aws/credentials"

export AWS_CONFIG_FILE="${JUMP_HOST_AWS_HOME}/.aws/config"
export AWS_SHARED_CREDENTIALS_FILE="${JUMP_HOST_AWS_HOME}/.aws/credentials"

_jh_aws_cleanup() {
  local home="${JUMP_HOST_AWS_HOME:-}"
  local root="${HOME}/.cache/jump-host-aws"
  [[ -n "$home" ]] || return 0
  case "$home" in
    "${root}"/*) rm -rf "$home" ;;
  esac
}
trap _jh_aws_cleanup EXIT

unset _jh_aws_root
```

Note: when `source`d from bats, `return` works; when bats runs via `bash -c 'source …'`, EXIT trap must fire when that bash exits.

- [ ] **Step 4: Install via Ansible**

In `ansible/roles/session_comfort/tasks/main.yml`, after the PATH profile.d task, add:

```yaml
- name: Install jump host profile.d AWS session isolation snippet
  ansible.builtin.copy:
    src: jump-host-aws-session.sh
    dest: /etc/profile.d/jump-host-aws-session.sh
    owner: root
    group: root
    mode: "0644"
```

- [ ] **Step 5: Run bats until green**

```bash
bats tests/shell/awslogin-session.bats
```

Expected: profile.d tests PASS (awslogin tests may still be absent).

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/session_comfort/files/jump-host-aws-session.sh \
  ansible/roles/session_comfort/tasks/main.yml \
  tests/shell/awslogin-session.bats
git commit -m "$(cat <<'EOF'
feat: add profile.d AWS session home for shared ec2-user

Create a per-shell credential directory under ~/.cache/jump-host-aws and export AWS config paths with a best-effort EXIT cleanup trap.
EOF
)"
```

---

### Task 2: Session-aware `awslogin` (TDD)

**Files:**
- Modify: `ansible/roles/session_comfort/files/awslogin`
- Modify: `tests/shell/awslogin-session.bats` (add awslogin cases)
- Verify: `tests/shell/awslogin-kubelogin.bats` still passes

**Interfaces:**
- Consumes: `AWS_PROFILE`, optional `JUMP_HOST_AWS_HOME` / `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE`
- Produces: session credentials file; session config without `sso_*` for the active profile

- [ ] **Step 1: Write failing bats for session-aware awslogin**

Append to `tests/shell/awslogin-session.bats` (reuse setup; extend fake `aws`):

```bash
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
  # shellcheck disable=SC1090
  source "$SESSION_SH"
  export AWS_PROFILE=jump-sso
  durable_before="$(cksum "$HOME_DIR/.aws/config")"
  run "$AWSLOGIN"
  echo "status=$status output=$output log=$(cat "$AWS_LOG")"
  [[ "$status" -eq 0 ]]
  grep -q 'sso login' "$AWS_LOG"
  grep -q 'export-credentials' "$AWS_LOG"
  # First aws invocations for login/export must use session HOME
  grep -q "HOME=${JUMP_HOST_AWS_HOME}" "$AWS_LOG"
  [[ -s "$AWS_SHARED_CREDENTIALS_FILE" ]]
  grep -q 'ASIATESTACCESS' "$AWS_SHARED_CREDENTIALS_FILE"
  grep -q '\[jump-sso\]' "$AWS_SHARED_CREDENTIALS_FILE"
  ! grep -q 'sso_start_url' "$AWS_CONFIG_FILE"
  grep -q 'region = us-west-2' "$AWS_CONFIG_FILE"
  [[ "$(cksum "$HOME_DIR/.aws/config")" == "$durable_before" ]]
  grep -q 'sso_start_url' "$HOME_DIR/.aws/config"
}
```

- [ ] **Step 2: Run new tests — expect FAIL on session path**

```bash
bats tests/shell/awslogin-session.bats --filter 'awslogin with session'
```

Expected: FAIL (current `awslogin` only runs `sso login`).

- [ ] **Step 3: Implement session-aware `awslogin`**

Replace `ansible/roles/session_comfort/files/awslogin` with:

```bash
#!/usr/bin/env bash
# Jump-host helper: SSO login with device code (no browser; SSM sessions have none).
# When JUMP_HOST_AWS_HOME is set (shared-user session isolation), cache SSO under the
# session tree, export short-lived keys into AWS_SHARED_CREDENTIALS_FILE, and strip
# sso_* from the session AWS_CONFIG_FILE only.
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

profile="${AWS_PROFILE:-}"
[[ -n "$profile" ]] || die "AWS_PROFILE is not set. Export AWS_PROFILE (typically via jump_host_login_env)."
command -v aws >/dev/null 2>&1 || die "aws CLI not found on PATH."
require_safe_profile() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unsafe AWS profile name."
}
require_safe_profile "$profile"

strip_sso_from_session_profile() {
  local cfg="$1" prof="$2" out
  out="$(mktemp)"
  # shellcheck disable=SC2016
  awk -v prof="$prof" '
    BEGIN { target = "[profile " prof "]"; in_target = 0 }
    /^\[/ {
      in_target = ($0 == target)
      print
      next
    }
    in_target {
      if ($0 ~ /^[[:space:]]*sso_/) next
      if ($0 ~ /^[[:space:]]*credential_process[[:space:]]*=/) next
    }
    { print }
  ' "$cfg" >"$out"
  mv "$out" "$cfg"
  chmod 600 "$cfg"
}

write_credentials_from_process_json() {
  local creds_file="$1" prof="$2" json="$3"
  local ak sk tok
  ak="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])')"
  sk="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])')"
  tok="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("SessionToken",""))')"
  {
    printf '[%s]\n' "$prof"
    printf 'aws_access_key_id = %s\n' "$ak"
    printf 'aws_secret_access_key = %s\n' "$sk"
    if [[ -n "$tok" ]]; then
      printf 'aws_session_token = %s\n' "$tok"
    fi
  } >"$creds_file"
  chmod 600 "$creds_file"
}

if [[ -z "${JUMP_HOST_AWS_HOME:-}" ]]; then
  exec aws sso login --profile "$profile" --no-browser --use-device-code
fi

# Session isolation path (shared ec2-user).
session_home="$JUMP_HOST_AWS_HOME"
session_cfg="${AWS_CONFIG_FILE:-$session_home/.aws/config}"
session_creds="${AWS_SHARED_CREDENTIALS_FILE:-$session_home/.aws/credentials}"
mkdir -p "${session_home}/.aws/sso/cache"

if [[ ! -s "$session_cfg" ]]; then
  if [[ -r "${HOME}/.aws/config" ]]; then
    cp "${HOME}/.aws/config" "$session_cfg"
    chmod 600 "$session_cfg"
  else
    die "No AWS config in session tree or durable ~/.aws/config."
  fi
fi

HOME="$session_home" aws sso login --profile "$profile" --no-browser --use-device-code

cred_json="$(HOME="$session_home" aws configure export-credentials --profile "$profile" --format process)"
[[ -n "$cred_json" ]] || die "export-credentials returned empty output."
write_credentials_from_process_json "$session_creds" "$profile" "$cred_json"
strip_sso_from_session_profile "$session_cfg" "$profile"

echo "Session credentials ready for profile ${profile}. Re-run awslogin when they expire." >&2
```

**Prefer `env-no-export` + pure bash** instead of process JSON + python3 (no python dependency on the helper). Final implementation should use:

```bash
ak=""; sk=""; tok=""
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    AWS_ACCESS_KEY_ID=*) ak="${line#AWS_ACCESS_KEY_ID=}" ;;
    AWS_SECRET_ACCESS_KEY=*) sk="${line#AWS_SECRET_ACCESS_KEY=}" ;;
    AWS_SESSION_TOKEN=*) tok="${line#AWS_SESSION_TOKEN=}" ;;
  esac
done < <(HOME="$session_home" aws configure export-credentials --profile "$profile" --format env-no-export)
[[ -n "$ak" && -n "$sk" ]] || die "export-credentials did not return access keys."
{
  printf '[%s]\n' "$profile"
  printf 'aws_access_key_id = %s\n' "$ak"
  printf 'aws_secret_access_key = %s\n' "$sk"
  if [[ -n "$tok" ]]; then
    printf 'aws_session_token = %s\n' "$tok"
  fi
} >"$session_creds"
chmod 600 "$session_creds"
strip_sso_from_session_profile "$session_cfg" "$profile"
echo "Session credentials ready for profile ${profile}. Re-run awslogin when they expire." >&2
```

Update the fake `aws` in tests to emit `env-no-export` lines when that format is requested. Drop the python/process-json helper from the final script.

- [ ] **Step 4: Run all related bats**

```bash
bats tests/shell/awslogin-session.bats tests/shell/awslogin-kubelogin.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/session_comfort/files/awslogin tests/shell/awslogin-session.bats
git commit -m "$(cat <<'EOF'
feat: materialize per-session credentials in awslogin for shared users

When JUMP_HOST_AWS_HOME is set, run SSO login under the session home, export short-lived keys, and strip sso_* from the session config only.
EOF
)"
```

---

### Task 3: Documentation and issue close-out

**Files:**
- Modify: `docs/jump-host-end-user-guide.md`
- Modify: `docs/access-model.md`

**Interfaces:**
- Consumes: implemented behavior from Tasks 1–2
- Produces: operator/admin docs; comment on issue #20

- [ ] **Step 1: Update end-user guide shared-user section**

Replace the “known gap / issue #20” paragraph with: shared `ec2-user` sessions get an isolated AWS home under `~/.cache/jump-host-aws/`; `awslogin` writes session credentials; exit cleans best-effort; still prefer per-user Run As. Update troubleshooting row that pointed at #20 as a gap.

- [ ] **Step 2: Update access-model.md**

Replace “tracked in issue #20” with a short description of the profile.d + `awslogin` isolation for `ec2-user`.

- [ ] **Step 3: Commit**

```bash
git add docs/jump-host-end-user-guide.md docs/access-model.md
git commit -m "$(cat <<'EOF'
docs: describe shared-user awslogin session credential isolation

Document the implemented per-shell AWS home and retire the issue #20 gap warning.
EOF
)"
```

- [ ] **Step 4: After merge (or with PR), comment on and close issue #20**

```bash
gh issue close 20 --comment "Implemented on branch/PR: per-shell AWS home under ~/.cache/jump-host-aws for ec2-user, awslogin login-then-export-keys, best-effort EXIT cleanup."
```

(Do this when the implementing PR is ready; if closing before merge, link the PR instead.)

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| profile.d session dir for ec2-user only | 1 |
| Env exports + EXIT trap | 1 |
| Ansible install to `/etc/profile.d/` | 1 |
| awslogin session path: HOME override, export keys, strip sso_* | 2 |
| awslogin without session env unchanged | 2 |
| Durable config never modified | 2 (test) |
| bats coverage | 1–2 |
| End-user + access-model docs | 3 |
| Close issue #20 | 3 |

## Placeholder scan

Plan includes concrete file paths, script bodies, and bats cases. Prefer `env-no-export` + bash parsing in the final `awslogin` (Task 2 Step 3 note). No TBD/TODO left in requirements.
