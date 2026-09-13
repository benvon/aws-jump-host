# Log-Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operators on a jump host can zip caller-supplied paths, multipart-upload the archive to a private per-environment S3 bucket, and get an AWS console object URL that goes through SSO login.

**Architecture:** A new Terragrunt stack `log-transfer` (Terraform module) sits beside `jump-hosts`. The instance role gets upload/multipart IAM; `users[].iam_role_arns` get download via bucket policy (SSO roles are not mutated). Ansible installs `/usr/local/bin/log-transfer` and `/etc/jump-host-log-transfer-{bucket,region}`. Uploads use instance-role credentials and AWS CLI multipart config, not `AWS_PROFILE`.

**Tech Stack:** Terraform ~> 1.10, AWS provider ~> 6.0, Terragrunt, Ansible, Bash 3.2-compatible helper, bats-core.

**Spec:** `docs/superpowers/specs/2026-09-11-log-transfer-design.md`

## Global Constraints

- Script name on PATH: `log-transfer`. Usage: `log-transfer <path> [path...]` (no default log dirs).
- Download is an S3 console object URL, never a presigned URL.
- One bucket per env/subenv/region; do not reuse `state_bucket` or the Ansible SSM transfer bucket.
- Bucket: all four Block Public Access flags, SSE-S3 (`AES256`) with bucket keys, Intelligent-Tiering, expire after 730 days, abort incomplete multipart after 7 days, HTTPS-only deny. No CMK, no access-log bucket, no versioning, no CRR, no `aws:SourceVpce` on downloader `GetObject`.
- Uploader IAM (instance role, identity + bucket policy): `s3:PutObject`, `s3:GetObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`, `s3:ListBucketMultipartUploads`, `s3:ListBucket`, `s3:GetBucketLocation`. Instance-role `GetObject`/`ListBucket` are intentional so operators can pull archives back onto the jump host.
- Downloader IAM (bucket policy, `users[].iam_role_arns`): `s3:GetObject`, `s3:ListBucket`, `s3:GetBucketLocation`. Empty ARN list is valid (uploads work; console GetObject 403).
- Upload uses instance role: unset `AWS_PROFILE` and `AWS_DEFAULT_PROFILE` for `aws s3 cp`. Process-local `AWS_CONFIG_FILE` with `multipart_threshold = 16MB` and `multipart_chunksize = 64MB`.
- Do not install AWS CLI in Ansible. `zip` is already in `session_comfort_base_packages`.
- Extra-vars names: `jump_host_log_transfer_bucket`, `jump_host_log_transfer_region` (optional `*_extra` overlay). Config files: `/etc/jump-host-log-transfer-bucket`, `/etc/jump-host-log-transfer-region`. Test overrides: `JUMP_HOST_LOG_TRANSFER_BUCKET`, `JUMP_HOST_LOG_TRANSFER_REGION`.
- Object key: `<linux-user>/<YYYYMMDDTHHMMSSZ>-<hostname>-<4-char suffix>.zip`. Console URL: `https://s3.console.aws.amazon.com/s3/object/<bucket>?region=<region>&prefix=<key>`
- Apply order: observability → vpc-endpoints → jump-hosts → log-transfer. Destroy: log-transfer → jump-hosts → vpc-endpoints → observability.
- Helper must work under `set -euo pipefail` on Bash 3.2 (`/bin/bash`) and Bash 4+.

## File structure

| Path | Responsibility |
| --- | --- |
| `ansible/roles/session_comfort/files/log-transfer` | Host helper (zip, multipart `s3 cp`, console URL). |
| `tests/shell/log-transfer.bats` | Unit tests for the helper with fake `aws`/`zip`. |
| `ansible/roles/session_comfort/tasks/main.yml` | Install helper; publish/remove `/etc` bucket+region files. |
| `ansible/roles/session_comfort/defaults/main.yml` | Empty bucket/region fallbacks. |
| `ansible/group_vars/all.yml` | `jump_host_log_transfer_bucket` / `_region` defaults. |
| `modules/terraform/jump_hosts/outputs.tf` | `instance_role_arn`, `instance_role_name`. |
| `modules/terraform/log_transfer/{main,variables,outputs}.tf` | Bucket, lifecycle, IT, policies. |
| `modules/terraform/log_transfer/README.md` | Module inputs/outputs. |
| `examples/live/*/*/log-transfer/terragrunt.hcl` | Example stacks (four regions). |
| `scripts/orchestrate.sh` | Required stack, apply/destroy order, configure extra-vars. |
| `tests/shell/bin/terragrunt` | Fake `output -raw` for configure tests. |
| `tests/shell/orchestrate.bats` | Order assertions. |
| `.github/workflows/aws-plan-optional.yml` | Include `log-transfer` in the plan loop. |
| Docs listed in the spec | Operator/consumer/architecture/cost/examples. |

Do not add a new Ansible role. Do not put S3 resources in `jump_hosts`.

---

### Task 1: `log-transfer` helper (TDD)

**Files:**
- Create: `tests/shell/log-transfer.bats`
- Create: `ansible/roles/session_comfort/files/log-transfer`
- Test: `tests/shell/log-transfer.bats`

**Interfaces:**
- Consumes: nothing from later tasks (bucket/region via env or `/etc` files).
- Produces: executable `log-transfer` that prints one console URL on success; exits non-zero with stderr and no URL on failure. Uses `JUMP_HOST_LOG_TRANSFER_BUCKET` / `JUMP_HOST_LOG_TRANSFER_REGION` when set.

- [ ] **Step 1: Write the failing bats tests**

Create `tests/shell/log-transfer.bats`:

```bash
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
  printf 'hello\n' >"$SRC_DIR/app.log"
  mkdir -p "$SRC_DIR/nested"
  printf 'inner\n' >"$SRC_DIR/nested/a.txt"

  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
{
  echo "PROFILE=${AWS_PROFILE-<unset>}"
  echo "DEFAULT_PROFILE=${AWS_DEFAULT_PROFILE-<unset>}"
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) shift ;;
    *)
      if [[ -z "$archive" ]]; then
        archive="$1"
      else
        paths+=("$1")
      fi
      shift
      ;;
  esac
done
mkdir -p "$(dirname "$archive")"
: >"$archive"
for p in "${paths[@]+"${paths[@]}"}"; do
  printf '%s\n' "$p" >>"$archive"
done
[[ -s "$archive" ]] || exit 1
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
  grep -q 'multipart_threshold = 16MB' "$AWS_LOG"
  grep -q 'multipart_chunksize = 64MB' "$AWS_LOG"
  ! find "$HOME_DIR/.cache/log-transfer" -name '*.zip' 2>/dev/null | grep -q .
}

@test "log-transfer prints no URL when aws s3 cp fails" {
  FAKE_AWS_FAIL=1 run "$LOG_TRANSFER" "$SRC_DIR/app.log"
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"s3.console.aws.amazon.com"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/shell/log-transfer.bats`

Expected: FAIL (helper missing or not executable).

- [ ] **Step 3: Implement the helper**

Create `ansible/roles/session_comfort/files/log-transfer` mode `0755`:

```bash
#!/usr/bin/env bash
# Jump-host helper: zip caller paths, multipart-upload to the log-transfer bucket, print console URL.
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

trim_file() {
  local f="$1"
  [[ -r "$f" ]] || return 0
  tr -d '\n\r' <"$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

[[ $# -ge 1 ]] || die "Usage: log-transfer <path> [path...]"

for p in "$@"; do
  [[ -e "$p" && -r "$p" ]] || die "Path missing or unreadable: $p"
done

command -v zip >/dev/null 2>&1 || die "zip not found on PATH."
command -v zipinfo >/dev/null 2>&1 || die "zipinfo not found on PATH."
command -v aws >/dev/null 2>&1 || die "aws CLI not found on PATH."

bucket="${JUMP_HOST_LOG_TRANSFER_BUCKET:-}"
region="${JUMP_HOST_LOG_TRANSFER_REGION:-}"
if [[ -z "$bucket" ]]; then
  bucket="$(trim_file "${JUMP_HOST_LOG_TRANSFER_BUCKET_FILE:-/etc/jump-host-log-transfer-bucket}")"
fi
if [[ -z "$region" ]]; then
  region="$(trim_file "${JUMP_HOST_LOG_TRANSFER_REGION_FILE:-/etc/jump-host-log-transfer-region}")"
fi
[[ -n "$bucket" ]] || die "No log-transfer bucket configured (set JUMP_HOST_LOG_TRANSFER_BUCKET or /etc/jump-host-log-transfer-bucket)."
[[ -n "$region" ]] || die "No log-transfer region configured (set JUMP_HOST_LOG_TRANSFER_REGION or /etc/jump-host-log-transfer-region)."

[[ -n "${HOME:-}" ]] || die "HOME is not set; cannot write zip cache."

user_name="$(id -un)"
host_name="$(hostname -s 2>/dev/null || hostname)"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
suffix="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n' | tr 'A-F' 'a-f')"
[[ ${#suffix} -eq 4 ]] || die "Could not generate a 4-character object-key suffix."
key="${user_name}/${ts}-${host_name}-${suffix}.zip"

work_dir="${HOME}/.cache/log-transfer/$$"
mkdir -p "$work_dir"
zip_path="${work_dir}/archive.zip"
aws_config="${work_dir}/aws-config"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

zip -r "$zip_path" "$@" >/dev/null
zipinfo -1 "$zip_path" | grep -q . || die "Zip archive is empty."

cat >"$aws_config" <<'EOF'
[default]
s3 =
    multipart_threshold = 16MB
    multipart_chunksize = 64MB
    max_concurrent_requests = 4
EOF

env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
  AWS_CONFIG_FILE="$aws_config" \
  aws s3 cp "$zip_path" "s3://${bucket}/${key}" \
    --region "$region" \
    --only-show-errors

printf 'https://s3.console.aws.amazon.com/s3/object/%s?region=%s&prefix=%s\n' "$bucket" "$region" "$key"
```

`env -u` is in POSIX env (GNU and BSD). If a future target lacks it, fail the task and switch to a subshell `unset`. Amazon Linux 2023 and macOS have `env -u`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/shell/log-transfer.bats`

Expected: `5 tests, 0 failures`.

Also run: `shellcheck ansible/roles/session_comfort/files/log-transfer`

Expected: no warnings (add `# shellcheck disable=` only if a finding is a false positive and document why).

- [ ] **Step 5: Commit**

```bash
git add tests/shell/log-transfer.bats ansible/roles/session_comfort/files/log-transfer
git commit -m "$(cat <<'EOF'
feat: add log-transfer helper to zip paths and print S3 console URL

EOF
)"
```

---

### Task 2: Ansible install of helper and `/etc` files

**Files:**
- Modify: `ansible/roles/session_comfort/tasks/main.yml` (merge facts ~lines 8–36; helper copy loop ~113–122; after eks-cluster publish/remove ~162–175)
- Modify: `ansible/roles/session_comfort/defaults/main.yml`
- Modify: `ansible/group_vars/all.yml`

**Interfaces:**
- Consumes: helper file from Task 1.
- Produces: extra-vars `jump_host_log_transfer_bucket` / `jump_host_log_transfer_region` (and `*_extra`) merged into `session_comfort_log_transfer_*_effective`; files `/etc/jump-host-log-transfer-bucket` and `/etc/jump-host-log-transfer-region`.

- [ ] **Step 1: Add defaults and group_vars**

In `ansible/roles/session_comfort/defaults/main.yml` after `session_comfort_eks_cluster_name`:

```yaml
session_comfort_log_transfer_bucket: ""
session_comfort_log_transfer_region: ""
```

In `ansible/group_vars/all.yml` after `jump_host_eks_cluster_name: ""`:

```yaml
# Log-transfer bucket/region for /usr/local/bin/log-transfer (written to /etc/jump-host-log-transfer-*).
# orchestrate.sh configure sets these from the log-transfer stack outputs.
jump_host_log_transfer_bucket: ""
jump_host_log_transfer_region: ""
```

- [ ] **Step 2: Merge facts, copy helper, publish/remove `/etc` files**

In the existing `set_fact` task in `ansible/roles/session_comfort/tasks/main.yml`, add:

```yaml
    session_comfort_log_transfer_bucket_effective: >-
      {{
        jump_host_log_transfer_bucket_extra
        | default(jump_host_log_transfer_bucket | default(session_comfort_log_transfer_bucket))
        | trim
      }}
    session_comfort_log_transfer_region_effective: >-
      {{
        jump_host_log_transfer_region_extra
        | default(jump_host_log_transfer_region | default(session_comfort_log_transfer_region))
        | trim
      }}
```

Change the helper copy loop to:

```yaml
- name: Install jump-host AWS SSO, kubeconfig, and log-transfer helpers
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/usr/local/bin/{{ item }}"
    owner: root
    group: root
    mode: "0755"
  loop:
    - awslogin
    - kubelogin
    - log-transfer
```

Immediately after the eks-cluster remove task, add:

```yaml
- name: Publish /etc/jump-host-log-transfer-bucket when configured
  ansible.builtin.copy:
    content: "{{ session_comfort_log_transfer_bucket_effective }}\n"
    dest: /etc/jump-host-log-transfer-bucket
    owner: root
    group: root
    mode: "0644"
  when: session_comfort_log_transfer_bucket_effective | length > 0

- name: Remove stale /etc/jump-host-log-transfer-bucket when empty
  ansible.builtin.file:
    path: /etc/jump-host-log-transfer-bucket
    state: absent
  when: session_comfort_log_transfer_bucket_effective | length == 0

- name: Publish /etc/jump-host-log-transfer-region when configured
  ansible.builtin.copy:
    content: "{{ session_comfort_log_transfer_region_effective }}\n"
    dest: /etc/jump-host-log-transfer-region
    owner: root
    group: root
    mode: "0644"
  when: session_comfort_log_transfer_region_effective | length > 0

- name: Remove stale /etc/jump-host-log-transfer-region when empty
  ansible.builtin.file:
    path: /etc/jump-host-log-transfer-region
    state: absent
  when: session_comfort_log_transfer_region_effective | length == 0
```

Do not add an AWS CLI package task.

- [ ] **Step 3: Lint / syntax-check**

Run:

```bash
ansible-playbook --syntax-check ansible/playbooks/jump_hosts.yml
ansible-lint ansible/roles/session_comfort ansible/group_vars/all.yml
```

Expected: syntax OK; ansible-lint 0 failures.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/session_comfort/tasks/main.yml ansible/roles/session_comfort/defaults/main.yml ansible/group_vars/all.yml
git commit -m "$(cat <<'EOF'
feat: install log-transfer helper and publish bucket config files

EOF
)"
```

---

### Task 3: `jump_hosts` instance role outputs

**Files:**
- Modify: `modules/terraform/jump_hosts/outputs.tf`
- Modify: `modules/terraform/jump_hosts/README.md` (outputs section)

**Interfaces:**
- Consumes: existing `aws_iam_role.instance` in `modules/terraform/jump_hosts/main.tf`.
- Produces: outputs `instance_role_arn` (string) and `instance_role_name` (string) for the `log_transfer` module.

- [ ] **Step 1: Add outputs**

Append to `modules/terraform/jump_hosts/outputs.tf`:

```hcl
output "instance_role_arn" {
  description = "IAM role ARN assumed by jump host EC2 instances."
  value       = aws_iam_role.instance.arn
}

output "instance_role_name" {
  description = "IAM role name assumed by jump host EC2 instances."
  value       = aws_iam_role.instance.name
}
```

Document both in `modules/terraform/jump_hosts/README.md` under outputs.

- [ ] **Step 2: Validate the module**

Run:

```bash
terraform -chdir=modules/terraform/jump_hosts init -backend=false -input=false -no-color
terraform -chdir=modules/terraform/jump_hosts validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add modules/terraform/jump_hosts/outputs.tf modules/terraform/jump_hosts/README.md
git commit -m "$(cat <<'EOF'
feat: export jump host instance role for log-transfer IAM

EOF
)"
```

---

### Task 4: Terraform `log_transfer` module

**Files:**
- Create: `modules/terraform/log_transfer/main.tf`
- Create: `modules/terraform/log_transfer/variables.tf`
- Create: `modules/terraform/log_transfer/outputs.tf`
- Create: `modules/terraform/log_transfer/README.md`

**Interfaces:**
- Consumes: `instance_role_arn`, `instance_role_name` from Task 3.
- Produces: outputs `bucket_name`, `bucket_arn`, `region` (`data.aws_region.current.id`).

- [ ] **Step 1: Write module files**

`modules/terraform/log_transfer/variables.tf`:

```hcl
variable "bucket_name" {
  description = "Globally unique S3 bucket name for jump-host log archives."
  type        = string
}

variable "instance_role_arn" {
  description = "Jump host instance role ARN allowed to upload archives."
  type        = string
}

variable "instance_role_name" {
  description = "Jump host instance role name to attach the upload inline policy."
  type        = string
}

variable "downloader_role_arns" {
  description = "IAM role ARNs allowed to download via the AWS console (typically users[].iam_role_arns). Empty means uploads only."
  type        = list(string)
  default     = []
}

variable "retention_days" {
  description = "Expire log-transfer objects after this many days."
  type        = number
  default     = 730
}

variable "force_destroy" {
  description = "Allow destroying a non-empty log-transfer bucket."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
```

`modules/terraform/log_transfer/main.tf` — include `terraform { required_version = "~> 1.10"; required_providers { aws = { source = "hashicorp/aws", version = "~> 6.0" } } }`, `data.aws_region.current`, `data.aws_caller_identity.current`, and:

- `locals.downloader_role_arns = distinct(compact(var.downloader_role_arns))`
- `aws_s3_bucket.this` with `bucket = var.bucket_name`, `force_destroy = var.force_destroy`, `tags = var.tags`
  - checkov skips on the bucket: `CKV_AWS_144` (no CRR), `CKV2_AWS_62` (no event notifications), `CKV_AWS_18` / logging (no access-log bucket), `CKV_AWS_21` (no versioning). Use the same comment style as `modules/terraform/remote_state_s3/main.tf`.
- `aws_s3_bucket_public_access_block.this` — all four flags `true`
- `aws_s3_bucket_server_side_encryption_configuration.this` — `sse_algorithm = "AES256"`, `bucket_key_enabled = true`
  - skip `CKV_AWS_145` (no CMK; SSE-S3 by design)
- `aws_s3_bucket_intelligent_tiering_configuration.entire_bucket` — `name = "entire-bucket"`, `status = "Enabled"` (no filter = whole bucket)
- `aws_s3_bucket_lifecycle_configuration.this` with two rules:
  - `expire-log-archives`: `expiration { days = var.retention_days }`
  - `abort-incomplete-multipart`: `abort_incomplete_multipart_upload { days_after_initiation = 7 }`
- `data.aws_iam_policy_document.bucket`:
  - Deny `s3:*` for principal `*` when `aws:SecureTransport` is `"false"` on bucket ARN and `/*`
  - Allow instance role (`var.instance_role_arn`) the uploader actions from Global Constraints. Object actions on `${aws_s3_bucket.this.arn}/*`; bucket actions (`ListBucket`, `GetBucketLocation`, `ListBucketMultipartUploads`) on `aws_s3_bucket.this.arn`
  - Dynamic statement if `length(local.downloader_role_arns) > 0`: allow those ARNs `s3:GetObject` on `/*` and `s3:ListBucket`, `s3:GetBucketLocation` on the bucket. **Do not** add `aws:SourceVpce`
- `aws_s3_bucket_policy.this`
- `data.aws_iam_policy_document.instance_upload` — same uploader actions, same resources
- `aws_iam_role_policy.upload` — `name` prefix `log-transfer-upload`, `role = var.instance_role_name`, `policy = data.aws_iam_policy_document.instance_upload.json`

`modules/terraform/log_transfer/outputs.tf`:

```hcl
output "bucket_name" {
  description = "Log-transfer S3 bucket name."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "Log-transfer S3 bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "region" {
  description = "AWS region of the log-transfer bucket."
  value       = data.aws_region.current.id
}
```

README: list inputs/outputs, note empty `downloader_role_arns`, Checkov skips, and that SSO roles are granted via bucket policy only.

- [ ] **Step 2: Format, validate, Checkov**

Run:

```bash
terraform fmt -recursive modules/terraform/log_transfer
terraform -chdir=modules/terraform/log_transfer init -backend=false -input=false -no-color
terraform -chdir=modules/terraform/log_transfer validate
checkov -d modules/terraform/log_transfer
```

Expected: validate success. Checkov failures only for documented skips already annotated; no unexpected FAILED checks. If Checkov adds a new CKV, annotate with the spec rationale (no CMK / no logging / no versioning / no CRR / no notifications) rather than changing the design.

- [ ] **Step 3: Commit**

```bash
git add modules/terraform/log_transfer
git commit -m "$(cat <<'EOF'
feat: add log_transfer S3 module with multipart-friendly IAM

EOF
)"
```

---

### Task 5: Example stacks, orchestrate, and order tests

**Files:**
- Create: `examples/live/dev/east/us-east-1/log-transfer/terragrunt.hcl`
- Create: `examples/live/dev/west/us-west-2/log-transfer/terragrunt.hcl`
- Create: `examples/live/stage/east/us-east-1/log-transfer/terragrunt.hcl`
- Create: `examples/live/prod/east/us-east-1/log-transfer/terragrunt.hcl`
- Modify: `scripts/orchestrate.sh` (`required_dirs` ~165; `run_ansible` extra-vars ~348; `case` init/plan/apply/destroy ~370–443)
- Modify: `tests/shell/bin/terragrunt` (add `output -raw`)
- Modify: `tests/shell/orchestrate.bats`
- Modify: `.github/workflows/aws-plan-optional.yml` (stack loop ~53)

**Interfaces:**
- Consumes: module from Task 4; `instance_role_*` outputs from Task 3; extra-var names from Task 2.
- Produces: stack path `<region>/log-transfer`; orchestrate extra-vars `jump_host_log_transfer_bucket` and `jump_host_log_transfer_region` on configure/apply/plan ansible runs.

- [ ] **Step 1: Add failing orchestrate order tests and fake `output -raw`**

In `tests/shell/bin/terragrunt`, after the `output -json` block, add:

```bash
if [[ "${1:-}" == output && "${2:-}" == -raw ]]; then
  case "${3:-}" in
    bucket_name)
      echo "example-log-transfer-bucket"
      exit 0
      ;;
    region)
      echo "us-east-1"
      exit 0
      ;;
  esac
  echo "fake: output -raw ${3:-} unavailable" >&2
  exit 1
fi
```

Append to `tests/shell/orchestrate.bats`:

```bash
@test "orchestrate apply runs log-transfer after jump-hosts" {
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
    --region us-east-1 \
    --auto-approve
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
j = text.find("jump-hosts")
l = text.find("log-transfer")
assert j != -1 and l != -1 and j < l, text
' "$log"
  rm -f "$log"
}

@test "orchestrate destroy runs log-transfer before jump-hosts" {
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
    --auto-approve
  [[ "$status" -eq 0 ]]
  python3 -c '
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
l = text.find("log-transfer")
j = text.find("jump-hosts")
assert l != -1 and j != -1 and l < j, text
' "$log"
  rm -f "$log"
}
```

Run: `bats tests/shell/orchestrate.bats`

Expected: new tests FAIL (no `log-transfer` dir and/or orchestrate does not call it). Existing destroy tests may also start failing once `required_dirs` includes `log-transfer` — add the example stacks before changing `required_dirs` if those tests error on missing directory.

- [ ] **Step 2: Add identical example `terragrunt.hcl` files**

Use this content in all four `log-transfer` example stacks (path to `root.hcl` and module source matches sibling stacks: `../../../../../../terragrunt/root.hcl` and `../../../../../../modules/terraform/log_transfer`):

```hcl
include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

locals {
  users_file = try(find_in_parent_folders("ansible/users.yaml"), "")
  users      = local.users_file != "" ? try(yamldecode(file(local.users_file)).users, []) : []
  downloader_role_arns = distinct(flatten([
    for user in local.users : try(user.iam_role_arns, [])
  ]))
}

dependency "jump_hosts" {
  config_path = "../jump-hosts"

  mock_outputs_allowed_in_commands = ["validate", "plan"]
  mock_outputs = {
    instance_role_arn  = "arn:aws:iam::111111111111:role/mock-jump-instance"
    instance_role_name = "mock-jump-instance"
  }
}

terraform {
  source = "../../../../../../modules/terraform/log_transfer"
}

inputs = {
  bucket_name = "jh-log-${include.root.locals.account_id}-${include.root.locals.env}-${include.root.locals.subenv}-${include.root.locals.aws_region}"
  instance_role_arn      = dependency.jump_hosts.outputs.instance_role_arn
  instance_role_name     = dependency.jump_hosts.outputs.instance_role_name
  downloader_role_arns   = local.downloader_role_arns
  retention_days         = 730
  tags = merge(include.root.locals.common_tags, {
    Component = "log-transfer"
  })
}
```

Bucket name must be lowercase, hyphens only, ≤63 characters. The `jh-log-${account}-${env}-${subenv}-${region}` pattern fits the example account id.

- [ ] **Step 3: Wire `orchestrate.sh`**

After `jump_hosts_dir=...` add:

```bash
log_transfer_dir="$region_dir/log-transfer"
```

Add `"$log_transfer_dir"` to `required_dirs`.

Add helper (near `resolve_ssm_transfer_bucket`):

```bash
resolve_log_transfer_outputs() {
  local bucket region
  if ! bucket="$(terragrunt --working-dir "$log_transfer_dir" output -raw bucket_name 2>/dev/null)"; then
    echo ""
    return 0
  fi
  if ! region="$(terragrunt --working-dir "$log_transfer_dir" output -raw region 2>/dev/null)"; then
    echo ""
    return 0
  fi
  bucket="$(printf '%s' "$bucket" | tr -d '\n\r')"
  region="$(printf '%s' "$region" | tr -d '\n\r')"
  if [[ -z "$bucket" || -z "$region" ]]; then
    echo ""
    return 0
  fi
  printf '%s\t%s\n' "$bucket" "$region"
}
```

In `run_ansible`, after users-vars extra-vars, add:

```bash
  local log_xfer
  log_xfer="$(resolve_log_transfer_outputs || true)"
  if [[ -n "$log_xfer" ]]; then
    extra+=(--extra-vars "jump_host_log_transfer_bucket=${log_xfer%%$'\t'*}")
    extra+=(--extra-vars "jump_host_log_transfer_region=${log_xfer#*$'\t'}")
  else
    printf "\n==> [ansible/%s] WARNING: log-transfer outputs unavailable; /etc/jump-host-log-transfer-* will be empty until that stack is applied.\n" "$playbook" >&2
  fi
```

`case` updates:

- `init`: `run_tg "$log_transfer_dir" init` after jump-hosts
- `plan`: `run_tg "$log_transfer_dir" plan` after jump-hosts, before `run_ansible`
- `apply`: `run_tg_apply "$log_transfer_dir"` after jump-hosts, before `run_ansible`
- `destroy`: `run_tg_destroy "$log_transfer_dir"` **before** `run_tg_destroy "$jump_hosts_dir"`

In `.github/workflows/aws-plan-optional.yml` change the loop to:

```bash
for name in observability vpc-endpoints jump-hosts log-transfer; do
```

- [ ] **Step 4: Run orchestrate bats**

Run: `bats tests/shell/orchestrate.bats`

Expected: all tests PASS, including the two new order tests. `apply` is slow only if it actually runs ansible; existing apply is not tested. If `apply` in the new test invokes ansible-playbook against 0 hosts, that is OK (inventory may be empty with fake tg). If apply fails because ansible-playbook is missing or inventory render fails, set the test to `plan` instead **and** keep destroy order test. Prefer testing `plan` for “log-transfer after jump-hosts” if apply cannot run in the bats environment:

If `apply` fails for ansible reasons, replace the apply test with `plan` (plan already calls `run_tg` then ansible check mode). Assert `jump-hosts` appears before `log-transfer` in `FAKE_TG_LOG` on `plan`. Keep destroy test as-is (`SKIP_PREFLIGHT` / fake tg).

- [ ] **Step 5: HCL format**

Run: `terragrunt hcl format --working-dir examples/live --exclude-dir .terragrunt-cache --exclude-dir .terraform`

Expected: files formatted; `make fmt-check` still passes for examples.

- [ ] **Step 6: Commit**

```bash
git add examples/live scripts/orchestrate.sh tests/shell/bin/terragrunt tests/shell/orchestrate.bats .github/workflows/aws-plan-optional.yml
git commit -m "$(cat <<'EOF'
feat: orchestrate log-transfer stack after jump-hosts

EOF
)"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/architecture.md` (component list ~25–30; data flow if it lists stacks)
- Modify: `docs/consumer-guide.md` (helpers paragraph ~154–157)
- Modify: `docs/jump-host-end-user-guide.md` (after awslogin/kubelogin ~83–94)
- Modify: `docs/cost-estimation.md` (optional features ~50–54)
- Modify: `examples/live/README.md` (stack list ~13–18)

**Interfaces:**
- Consumes: behavior from Tasks 1–5.
- Produces: operator and consumer docs matching the spec.

- [ ] **Step 1: Update docs**

`docs/architecture.md` — add bullet:

- `modules/terraform/log_transfer`: private per-environment bucket for operator log archives; instance-role upload and console download via `users[].iam_role_arns`.

Terragrunt hierarchy: mention `log-transfer` as a required stack beside `jump-hosts`.

`docs/consumer-guide.md` — after the kubelogin bullets:

```markdown
Per-environment `log-transfer` (S3 bucket + `/usr/local/bin/log-transfer`) needs:

- `users[].iam_role_arns` in extra-vars so those principals can `s3:GetObject` / `s3:ListBucket` via the **bucket policy** (Identity Center reserved roles are not mutated). If the list is empty, uploads still work but console downloads return 403 until ARNs are set and `log-transfer` is re-applied.
- `orchestrate.sh` apply/configure after the `log-transfer` stack exists so Ansible writes `/etc/jump-host-log-transfer-bucket` and `/etc/jump-host-log-transfer-region`.
```

`docs/jump-host-end-user-guide.md` — after the kubelogin section:

```markdown
### On the jump host: `log-transfer`

Package local files or directories and upload them for browser download via the AWS console:

```bash
log-transfer /path/to/file.log ./coredump.dir
```

The command prints an S3 console URL. Open it, sign in with SSO if prompted, and download the object. You need an IAM role listed in this environment’s `users.yaml` `iam_role_arns`. Archives expire after two years. You need free space on `/home` roughly equal to the zip size while it is being built.
```

`docs/cost-estimation.md` optional features — add:

- Log-transfer S3: Intelligent-Tiering storage for infrequent archives; default expire after 730 days. Usually small unless operators upload large dumps often. No extra KMS CMK.

`examples/live/README.md` stack list — add `- log-transfer`.

Do not add new required keys to `ansible/vars-schema.example.yml` (`iam_role_arns` already exists).

- [ ] **Step 2: Sanity grep**

Run: `rg -n 'log-transfer|log_transfer' docs examples/live/README.md`

Expected: hits in the files above; no presigned-URL wording.

- [ ] **Step 3: Commit**

```bash
git add docs examples/live/README.md
git commit -m "$(cat <<'EOF'
docs: describe log-transfer bucket, helper, and IAM

EOF
)"
```

---

## Self-review (plan vs spec)

| Spec item | Task |
| --- | --- |
| Console URL, not presigned | 1, 6 |
| Downloaders = `iam_role_arns` via bucket policy | 4, 5, 6 |
| CLI paths only | 1 |
| One bucket per env/subenv/region | 5 |
| Dedicated stack, not state/SSM bucket | 4, 5 |
| Multipart CLI config 16MB/64MB | 1 |
| Abort incomplete multipart 7 days | 4 |
| 730-day expire, SSE-S3, IT, no public access | 4 |
| No SourceVpce on GetObject | 4 |
| Identity + resource policy for instance | 4 |
| `jump_hosts` role outputs | 3 |
| Ansible helper + `/etc` files | 2 |
| Unset AWS_PROFILE on upload | 1 |
| orchestrate apply after / destroy before jump-hosts | 5 |
| Empty downloader list allowed | 4, 6 |
| Bats helper + orchestrate order | 1, 5 |
| Checkov skips as specified | 4 |
| Docs list in spec | 6 |
| Do not install AWS CLI | 2 |

No TBD/TODO left in tasks. Names used later match earlier tasks: `instance_role_arn`, `instance_role_name`, `bucket_name`, `region`, `jump_host_log_transfer_bucket`, `jump_host_log_transfer_region`, `log-transfer`.
