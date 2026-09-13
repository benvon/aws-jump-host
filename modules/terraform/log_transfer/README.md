# log_transfer module

Creates a private S3 bucket for jump-host log archives with multipart-friendly upload IAM on the existing instance role and optional console download access via bucket policy.

## Inputs

- `bucket_name` (string): globally unique S3 bucket name.
- `instance_role_arn` (string): jump host instance role ARN allowed to upload archives (from `jump_hosts` outputs).
- `instance_role_name` (string): jump host instance role name for the upload inline policy (from `jump_hosts` outputs).
- `downloader_role_arns` (list(string), default `[]`): IAM role ARNs allowed to download via the AWS console (typically flattened `users[].iam_role_arns`). Empty means uploads only; console downloads return 403 until ARNs are set.
- `retention_days` (number, default `730`): expire objects after this many days.
- `force_destroy` (bool, default `false`): allow destroying a non-empty bucket.
- `tags` (map(string), default `{}`)

## Outputs

- `bucket_name`
- `bucket_arn`
- `region` (from the AWS provider region)

## Notes

- Upload permissions are granted both in the bucket policy (instance role ARN) and via an inline policy on the jump-host instance role. The instance role can upload (`PutObject` and multipart) and also `GetObject` / `ListBucket` so operators can pull an archive back onto the jump host with instance-role credentials. Console download after SSO still uses `downloader_role_arns`. All local users share the instance role, so host-side list/get is not scoped per Linux user.
- Downloader access is granted only through the bucket policy. IAM Identity Center (`AWSReservedSSO_*`) roles are not mutated; list their ARNs in `downloader_role_arns` instead.
- Empty `downloader_role_arns` omits the downloader statement from the bucket policy so Terraform does not emit an invalid principal.
- Uploads use the `INTELLIGENT_TIERING` storage class; optional `ARCHIVE_ACCESS` tiering is clamped to at most 730 days (S3 API maximum).
- Checkov skips (documented on resources): no customer-managed KMS (`CKV_AWS_145`), no access-log bucket (`CKV_AWS_18`), no versioning (`CKV_AWS_21`), no event notifications (`CKV2_AWS_62`), no cross-region replication (`CKV_AWS_144`).
- tfsec skips (documented on resources): no customer-managed KMS (`aws-s3-encryption-customer-key`), no access-log bucket (`aws-s3-enable-bucket-logging`), no versioning (`aws-s3-enable-versioning`). Event notifications and CRR are covered by Checkov only (no matching tfsec rules in v1.28).
