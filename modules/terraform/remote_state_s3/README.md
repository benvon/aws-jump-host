# remote_state_s3 module

Creates an encrypted, versioned S3 bucket for Terraform state.

## Inputs

- `state_bucket_name` (string)
- `kms_key_arn` (string|null): optional customer-managed KMS key.
- `force_destroy` (bool, default `false`)
- `tags` (map(string))

## Outputs

- `state_bucket_name`
- `state_bucket_arn`

## Concurrency Note

This repository intentionally uses an S3-only backend posture (no DynamoDB locking), which means concurrent state operations must be controlled operationally.
