# vpc_endpoints_ssm module

Creates shared interface endpoints for private Session Manager and CloudWatch Logs connectivity in a VPC.

## Inputs

- `vpc_id` (string)
- `subnet_ids` (list(string))
- `security_group_ids` (list(string))
- `private_dns_enabled` (bool, default `true`)
- `create_kms_endpoint` (bool, default `false`)
- `tags` (map(string))

## Outputs

- `endpoint_ids`
- `endpoint_dns_names`
