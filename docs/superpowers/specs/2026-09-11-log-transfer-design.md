# Log-transfer bucket and jump-host helper

Date: 2026-09-11  
Status: approved design (implemented). The jump-host EC2 instance role is SSM-only; operators bring their own credentials for `log-transfer`.

## Goal

Operators on a jump host can zip caller-supplied local files/directories, upload the archive to a private per-environment S3 bucket using multipart upload, and receive an AWS console object URL. Opening that URL sends them through console/SSO login; download uses their IAM Identity Center (or IAM) role, not a presigned anonymous link.

## Non-goals

- Presigned URLs, CloudFront, or a custom download portal
- Default log paths or an interactive file picker
- Mutating Identity Center permission sets or `AWSReservedSSO_*` role inline policies
- Sharing one bucket across environments, regions, or accounts
- Customer-managed KMS, S3 access logging, or Cross-Region Replication

## Decisions

| Topic | Choice |
| --- | --- |
| Download | S3 console object URL (login, then object) |
| Who can upload/download | `users.yaml` / extra-vars `users[].iam_role_arns` (v1, whole bucket). The EC2 instance role is not granted S3 access. |
| Instance IAM | SSM agent and interactive Session Manager only. Operators bring their own Identity Center / IAM credentials for environment APIs, including `log-transfer`. |
| What to zip | Only paths passed on the CLI |
| Bucket cardinality | One per env/subenv/region |
| Layout | Dedicated Terragrunt stack + Terraform module (not inside `jump_hosts`, not the state/SSM-transfer bucket) |
| Upload | AWS CLI `s3 cp` with explicit multipart threshold/chunk size |
| Retention | 730 days, then expire |
| Cost/security defaults | Block all public access, SSE-S3, Intelligent-Tiering, HTTPS-only, abort incomplete multipart after 7 days, no extra KMS CMK, no access-log bucket, no versioning |

## Architecture

New stack `log-transfer` lives beside `jump-hosts` in the live layout:

`<live-root>/<env>/<subenv>/<region>/log-transfer`

`orchestrate.sh` applies it **after** `jump-hosts` and destroys it **before** `jump-hosts`.

Uploads stay on the existing S3 gateway VPC endpoint. Console downloads happen from the operator’s browser using their SSO/IAM credentials; the bucket policy must **not** require `aws:SourceVpce` on `GetObject`.

Same-account S3 allows an allow from identity **or** resource policy. This design uses **resource policy only**: bucket policy for operator `iam_role_arns` (upload and download). Reserved SSO roles are not mutated. The jump-host instance role stays SSM-only (agent + interactive sessions) and is not granted log-transfer S3 actions.

## Components

### Terraform module `modules/terraform/log_transfer`

Creates:

- Bucket (name from input; globally unique)
- `aws_s3_bucket_public_access_block` (all four flags true)
- SSE-S3 (`AES256`) with bucket keys
- Intelligent-Tiering configuration for the whole bucket
- Lifecycle: expire objects after `retention_days` (default 730); abort incomplete multipart after 7 days
- Bucket policy:
  - Deny `s3:*` when `aws:SecureTransport` is false
  - Allow each operator role ARN (`downloader_role_arns` / `users[].iam_role_arns`): `s3:PutObject` (covers create/upload-part/complete multipart), `s3:GetObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`, `s3:ListBucketMultipartUploads`, `s3:ListBucket`, `s3:GetBucketLocation`
- No inline IAM policy on the jump-host instance role

Accepted Checkov/tfsec skips (documented on the resources): no CMK, no access-log bucket, no versioning, no event notifications, no CRR.

Inputs (minimum): `bucket_name`, `downloader_role_arns` (list, may be empty), `retention_days`, `tags`.

Outputs: `bucket_name`, `bucket_arn`, `region` (from provider).

Empty `downloader_role_arns` is valid Terraform: nobody can upload or download until ARNs are set. Document that in the consumer guide.

### Terragrunt stack

`examples/live/<env>/<subenv>/<region>/log-transfer/terragrunt.hcl`:

- Flatten unique `users[].iam_role_arns` from the extra-vars file (same `find_in_parent_folders` pattern as private `ssm-self-management`; examples may pass a local path or empty list)
- Fail closed through `scripts/validate_users_vars.py` (the users policy helper: orchestrate, Ansible `user_accounts --json`, and each log-transfer stack via `run_cmd --print-downloader-arns`). Rules match what `useradd`/`ansible.builtin.user` would accept, including Linux username syntax, unique names, list types, and present-vs-null optional keys. Downloader ARNs come only from that helper (absent users omitted). Orchestrate exports `JUMP_HOST_USERS_VALIDATOR` so `run_cmd` still finds that script when `--live-dir` is a separate repository (`get_repo_root()` would not).
- Default bucket name derived from account id, env, subenv, and region (63-char S3 limit; hyphens only). Overridable via input.

### `orchestrate.sh`

Required stack directory `log-transfer` next to `jump-hosts`.

| Action | Order |
| --- | --- |
| init / plan / apply | observability → vpc-endpoints → jump-hosts → **log-transfer** |
| destroy | **log-transfer** → jump-hosts → … |

`configure` reads Terragrunt outputs `bucket_name` and `region`, rejects values that are not a safe S3 bucket name or AWS region id, and passes Ansible extra-vars (e.g. `jump_host_log_transfer_bucket`, `jump_host_log_transfer_region`).

### Ansible `session_comfort`

- Copy helper to `/usr/local/bin/log-transfer` (mode 0755)
- Publish `/etc/jump-host-log-transfer-bucket` and `/etc/jump-host-log-transfer-region` when extra-vars are non-empty; remove those files when empty (same pattern as `/etc/jump-host-eks-cluster`)
- `zip` is already in `session_comfort_base_packages`; AWS CLI is already on Amazon Linux 2023 (do not install it)

### Helper `/usr/local/bin/log-transfer`

Usage: `log-transfer <path> [path...]`

Behavior:

1. Require at least one path; each path must exist and be readable.
2. Read bucket and region from `/etc/jump-host-log-transfer-*` (overridable with `JUMP_HOST_LOG_TRANSFER_BUCKET` / `JUMP_HOST_LOG_TRANSFER_REGION` for tests).
3. Create a zip under a uniquely created directory in `$HOME/.cache/log-transfer` (persistent home volume, not root disk; `mktemp -d` so a reused PID cannot reopen a leftover archive). Include the given files/directories; rewrite a path that is exactly `-` to `./-` so Info-ZIP archives that filesystem name instead of stdin. Fail if the zip is empty.
4. Object key: `<linux-user>/<UTC timestamp YYYYMMDDTHHMMSSZ>-<hostname>-<4-char suffix>.zip`.
5. Upload with `aws s3 cp` using:
   - **Operator credentials** — keep `AWS_PROFILE` / `AWS_DEFAULT_PROFILE` / access keys from the session (`jump_host_login_env` SSO). Profile selection is `AWS_PROFILE`, then `AWS_DEFAULT_PROFILE`, then `default`. Disable IMDS (`AWS_EC2_METADATA_DISABLED=true`) so the instance role cannot be used. Unset leftover web-identity and container credential variables so they cannot override the operator profile.
   - S3 transfer settings are applied separately onto that profile in a process-local `AWS_CONFIG_FILE` (SSO keys are preserved). The helper inherits any existing nested `s3 =` values from the selected profile, then overrides `multipart_threshold = 16MB`, `multipart_chunksize = 64MB`, and `max_concurrent_requests = 4`. It prints one compact `log-transfer s3: ...` line on stderr with the effective settings.
6. On success, delete the local zip and print one S3 console object URL, then exit 0:

   `https://s3.console.aws.amazon.com/s3/object/<bucket>?region=<region>&prefix=<key>`

   (`prefix` is the object key; keys are not directory prefixes here.)

Operators need free disk on `/home` of about the archive size while the zip exists.

## Data flow

```
operator → log-transfer [paths]
        → zip on $HOME/.cache/log-transfer
        → aws s3 cp (multipart, operator credentials, S3 gateway endpoint)
        → stdout: console URL
operator browser → AWS console login/SSO → GetObject as iam_role_arns principal
lifecycle → expire object at 730 days; abort stale multipart at 7 days
```

## Error handling

The helper exits non-zero, prints a short stderr message, and **does not** print a console URL when:

- no paths, missing/unreadable path, missing `zip` or `aws`, missing/empty/unsafe bucket or region config, unsafe generated object key, empty zip, or `aws s3 cp` failure

A `trap` removes the temp zip on success and on most failures. Interrupted/failed multipart uploads are not aborted by the script; lifecycle deletes them after 7 days.

If the object exists but the operator’s role is not in `iam_role_arns` (or an SCP denies S3), the console shows a normal AWS access error. Fix: add the role to extra-vars and re-apply `log-transfer`.

## Testing

- **Bats** (`tests/shell/log-transfer.bats`): fake `aws` and `zip`; missing args/config fail; given files are zipped; `aws s3 cp` is invoked with the expected bucket/key and the operator `AWS_PROFILE` (IMDS disabled); multipart config is present (`multipart_threshold` / `multipart_chunksize`); stdout contains the console URL with bucket, region, and key; temp zip is gone after success; failed `cp` yields no URL.
- **Orchestrate bats**: `log-transfer` appears after jump-hosts on apply and before jump-hosts on destroy (extend `tests/shell/orchestrate.bats`; add the example stack so directory checks pass).
- **Ansible**: playbook syntax-check and ansible-lint for the new files/tasks.
- **Terraform**: `make validate` / Checkov on the new module; documented skips only as listed above.
- CI does not upload to real S3 or exercise console login. Multipart is asserted by CLI configuration, not by transferring gigabytes.

## Docs to update at implementation time

- `docs/architecture.md` — new module and stack
- `docs/consumer-guide.md` — extra-vars, IAM, apply order, empty-ARN warning
- `docs/jump-host-end-user-guide.md` — `log-transfer` usage and console download
- `docs/cost-estimation.md` — S3 Intelligent-Tiering / storage line (small, infrequent)
- `examples/live/README.md` — stack list
- `ansible/vars-schema.example.yml` — no new required user fields; ARNs already exist

## Implementation notes (non-ambiguous)

- Do not reuse `state_bucket` / Ansible SSM transfer bucket.
- Do not add `aws:SourceVpce` conditions on downloader `GetObject`.
- Do not install AWS CLI in Ansible for this feature.
- v1 downloader grant is the whole bucket for listed role ARNs (no per-Linux-user prefix IAM).
- Script name on PATH: `log-transfer`.
