# log_transfer module

Creates a private S3 bucket for jump-host log archives. Upload and download are granted only to operator IAM role ARNs from `users[].iam_role_arns` via bucket policy. The jump-host instance role is not granted S3 access.

## Inputs

- `bucket_name` (string): globally unique S3 bucket name.
- `downloader_role_arns` (list(string), default `[]`): IAM role ARNs allowed to upload and download (typically flattened `users[].iam_role_arns`). Empty means nobody can upload or download until ARNs are set.
- `retention_days` (number, default `730`): expire objects after this many days (maximum 730).
- `force_destroy` (bool, default `false`): allow destroying a non-empty bucket.
- `tags` (map(string), default `{}`)

## Outputs

- `bucket_name`
- `bucket_arn`
- `region` (from the AWS provider region)

## Notes

- Operators use their own SSO/IAM credentials (`AWS_PROFILE` or exported keys) for `log-transfer`. The helper disables IMDS so the EC2 instance role cannot be used as a fallback.
- Access is granted only through the bucket policy. IAM Identity Center (`AWSReservedSSO_*`) roles are not mutated; list their ARNs in `downloader_role_arns` instead.
- Empty `downloader_role_arns` omits the operator statements from the bucket policy so Terraform does not emit an invalid principal. Uploads and console downloads then return 403 until ARNs are set.
- Uploads use the `INTELLIGENT_TIERING` storage class; optional `ARCHIVE_ACCESS` tiering is clamped to at most 730 days (S3 API maximum).
- Checkov skips (documented on resources): no customer-managed KMS (`CKV_AWS_145`), no access-log bucket (`CKV_AWS_18`), no versioning (`CKV_AWS_21`), no event notifications (`CKV2_AWS_62`), no cross-region replication (`CKV_AWS_144`).
- tfsec skips (documented on resources): no customer-managed KMS (`aws-s3-encryption-customer-key`), no access-log bucket (`aws-s3-enable-bucket-logging`), no versioning (`aws-s3-enable-versioning`). Event notifications and CRR are covered by Checkov only (no matching tfsec rules in v1.28).
