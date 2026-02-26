# remote_state_s3 module

Creates an encrypted, versioned S3 bucket for Terraform state and enables server access logging for that bucket.

## Inputs

- `state_bucket_name` (string)
- `kms_key_arn` (string|null): optional customer-managed KMS key.
- `access_log_bucket_name` (string|null): optional access-log bucket name. Defaults to `<state_bucket_name>-access-logs`.
- `access_log_prefix` (string, default `s3-access-logs`)
- `access_log_retention_days` (number, default `365`)
- `force_destroy` (bool, default `false`)
- `tags` (map(string))

## Outputs

- `state_bucket_name`
- `state_bucket_arn`
- `access_log_bucket_name`
- `access_log_bucket_arn`

## Notes

- The dedicated access-log bucket is intentionally not itself access-logged to avoid recursive logging chains.
- The dedicated access-log bucket uses AWS-managed KMS (`aws/s3`) encryption by default.
- This repository intentionally uses an S3-only backend posture (no DynamoDB locking), which means concurrent state operations must be controlled operationally.
