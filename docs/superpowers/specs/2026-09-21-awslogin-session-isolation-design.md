# Per-session awslogin credential isolation (issue #20)

Status: approved design (pending implementation).

## Problem

When Session Manager Run As lands operators on a **shared** Linux user (`ec2-user`), `awslogin` caches IAM Identity Center tokens under that shared `$HOME` (typically `~/.aws/sso/cache`). Concurrent sessions with the same UID can reuse those tokens until they expire and may impersonate an operator with broader permissions.

Per-user Run As avoids this by giving each operator a private home and remains the preferred deployment model. Shared-user environments need an additional isolation mechanism.

Tracking: [issue #20](https://github.com/benvon/aws-jump-host/issues/20).

## Goals

1. Under shared Linux users, concurrent Session Manager sessions must not reuse each other’s SSO token cache after `awslogin`.
2. Keep Linux `$HOME` as the real home (`/home/ec2-user`) for `cd`, persistent files, and shell UX.
3. Operator UX stays `awslogin` then normal `aws` / helpers (`kubelogin`, `log-transfer`); re-run `awslogin` when short-lived keys expire.
4. Best-effort cleanup of the session credential directory on shell exit (tokens are time-bound; hard kills may leave leftovers).

## Non-goals

- Changing IMDS / instance-role IAM policy
- Requiring per-user Run As (still recommended; this is the shared-user mitigation)
- Isolating private per-user homes (no-op for those users)
- Perfect cleanup if the session is killed hard
- A dedicated AWS CLI SSO-cache env var (does not exist today)

## Decisions

| Topic | Choice |
| --- | --- |
| Isolation model | Session-scoped AWS home under `$HOME/.cache/jump-host-aws/<id>/` |
| When it applies | **Shared user only** (`id -un` is `ec2-user`) |
| Pointing CLI at session data | **Login-then-export-keys**: `HOME=$JUMP_HOST_AWS_HOME` only for `aws sso login` / export; then write keys to session credentials file and strip `sso_*` from the **session** config copy |
| Lifecycle owner | `profile.d` creates dir, exports env, registers `EXIT` trap; `awslogin` fills credentials |
| Session id | UUID (or `mktemp`-style suffix) at shell start; SSM does not reliably expose a session id into the shell |

## Architecture

### Components

1. **New Ansible `session_comfort` `profile.d` snippet** (e.g. `jump-host-aws-session.sh`) installed for all hosts; logic is a no-op unless the Linux user is shared.
2. **Reworked `/usr/local/bin/awslogin`** that detects session isolation env and performs login + credential materialization into the session tree.
3. **bats** coverage for profile.d behavior and `awslogin` with/without session env.
4. **Docs** updates (end-user guide, access-model); close issue #20 when shipped.

### Shared-user detection

Treat as shared when `id -un` equals `ec2-user` (this platform’s shared Run As default). No admin allowlist in v1 (YAGNI).

### Session directory layout

```
$HOME/.cache/jump-host-aws/<session-id>/
  .aws/config          # seeded copy of durable ~/.aws/config
  .aws/credentials     # written by awslogin after export
  .aws/sso/cache/      # SSO tokens for this session only (via HOME override during login)
```

Directory mode `0700`.

### `profile.d` behavior (shared users)

On interactive shell start:

1. Create `$HOME/.cache/jump-host-aws/<id>/` (`JUMP_HOST_AWS_SESSION_ID=<id>`).
2. Seed `.aws/config` by copying durable `$HOME/.aws/config` when present.
3. Export (do **not** change Linux `$HOME`):
   - `JUMP_HOST_AWS_HOME=<session dir>`
   - `AWS_CONFIG_FILE=$JUMP_HOST_AWS_HOME/.aws/config`
   - `AWS_SHARED_CREDENTIALS_FILE=$JUMP_HOST_AWS_HOME/.aws/credentials`
4. Register `trap` on `EXIT`: best-effort `rm -rf` of `$JUMP_HOST_AWS_HOME` only if it is under `$HOME/.cache/jump-host-aws/`.

Non-shared users: no directory, no AWS_* overrides, no trap.

### `awslogin` behavior

**When `JUMP_HOST_AWS_HOME` is unset** (per-user home): keep today’s behavior — `aws sso login --profile "$AWS_PROFILE" --no-browser --use-device-code` against normal `~/.aws`.

**When `JUMP_HOST_AWS_HOME` is set:**

1. Require `AWS_PROFILE`; ensure session `.aws/config` exists (seed/copy from durable home if missing).
2. Run:
   ```bash
   HOME="$JUMP_HOST_AWS_HOME" aws sso login --profile "$profile" --no-browser --use-device-code
   ```
   so SSO cache is written only under the session tree.
3. Run:
   ```bash
   HOME="$JUMP_HOST_AWS_HOME" aws configure export-credentials --profile "$profile" --format process
   ```
   and write short-lived keys into `AWS_SHARED_CREDENTIALS_FILE` for that profile name (INI section matching the profile).
4. Rewrite the **session** config profile to remove `sso_*` (and similar SSO-only keys) so later CLI/SDK resolution uses the credentials file, not SSO cache. **Never** modify durable `$HOME/.aws/config`.
5. Fail clearly if durable/session config or profile is missing, or if login/export fails.

### Why strip SSO from the session config

An SSO-configured named profile continues to prefer the SSO credential provider even when a shared credentials file exists for the same name. After export, the session copy of the profile must become a static-key profile (region retained; `sso_*` removed) so `AWS_PROFILE` + `AWS_SHARED_CREDENTIALS_FILE` work for `aws`, `kubelogin`, `log-transfer`, and SDKs without reading a shared `~/.aws/sso/cache`.

### Interaction with other helpers

- `kubelogin` / `log-transfer`: unchanged; they honor `AWS_PROFILE` and env. With session credentials + stripped session config they use operator keys.
- No host-level IMDS disable as a substitute for this isolation.

## Edge cases

| Case | Behavior |
| --- | --- |
| Missing durable `~/.aws/config` / profile | `awslogin` fails with a clear error |
| Nested interactive shells | Each gets its own session id/dir if `profile.d` runs; each trap cleans its own dir |
| Hard session kill | Trap may not run; leftover dirs under `.cache/jump-host-aws/` are acceptable; docs may note admins can prune |
| Keys expire mid-session | Operator re-runs `awslogin` |

## Testing

Extend `tests/shell/awslogin-kubelogin.bats` (and add focused tests for the profile.d script as needed):

- Shared-user profile.d creates dir, exports vars; EXIT trap removes dir.
- Non-shared user: no overrides.
- `awslogin` with session env: `sso login` runs with `HOME=$JUMP_HOST_AWS_HOME`; credentials file written; session config lacks `sso_*` for the profile; durable config untouched.
- `awslogin` without session env: existing device-code behavior preserved.
- Fake `aws` records env + args (including `HOME` and export-credentials).

## Documentation

- `docs/jump-host-end-user-guide.md`: replace “known gap / issue #20” wording with how shared-user isolation works; still prefer per-user Run As.
- `docs/access-model.md`: describe implemented behavior instead of “tracked in #20”.
- Close [issue #20](https://github.com/benvon/aws-jump-host/issues/20) when shipped.

## Success criteria

1. Two concurrent shared-user (`ec2-user`) sessions cannot reuse each other’s SSO cache after each runs `awslogin`.
2. `aws sts get-caller-identity` in each session reflects that session’s operator role (via session credentials).
3. Shell exit removes (best-effort) the session cache dir.
4. bats coverage green; durable `~/.aws/config` never modified by `awslogin`.
5. End-user and access-model docs updated.

## Implementation notes

- Bash 3.2 compatible (`/bin/bash` on Amazon Linux / macOS CI as applicable).
- After this spec is approved for implementation, write an implementation plan (writing-plans) before coding.
