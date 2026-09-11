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

- Upload permissions are granted both in the bucket policy (instance role ARN) and via an inline policy on the jump-host instance role.
- Downloader access is granted only through the bucket policy. IAM Identity Center (`AWSReservedSSO_*`) roles are not mutated; list their ARNs in `downloader_role_arns` instead.
- Empty `downloader_role_arns` omits the downloader statement from the bucket policy so Terraform does not emit an invalid principal.
- Checkov skips (documented on resources): no customer-managed KMS (`CKV_AWS_145`), no access-log bucket (`CKV_AWS_18`), no versioning (`CKV_AWS_21`), no event notifications (`CKV2_AWS_62`), no cross-region replication (`CKV_AWS_144`).
