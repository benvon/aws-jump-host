# observability module

Creates session logging dependencies for Session Manager, including a CloudWatch log group and optional KMS key.

## Inputs

- `log_group_name` (string)
- `retention_days` (number, default `365`)
- `kms_key_arn` (string|null)
- `create_kms_key` (bool, default `true`)
- `kms_alias_name` (string)
- `tags` (map(string))

## Outputs

- `cloudwatch_log_group_name`
- `cloudwatch_log_group_arn`
- `kms_key_arn`
