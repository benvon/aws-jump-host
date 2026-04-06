# vpc_endpoints_ssm module

Creates shared interface endpoints for private Session Manager and CloudWatch Logs connectivity in a VPC.

## Inputs

- `vpc_id` (string)
- `subnet_ids` (list(string))
- `security_group_ids` (list(string), default `[]`)
  - When non-empty, these are attached to every endpoint.
  - When empty, the module creates one managed security group per endpoint service with ingress `tcp/443` from the VPC CIDR and egress `tcp/443` to `0.0.0.0/0` (accepted risk for PrivateLink service-backend reachability).
- `private_dns_enabled` (bool, default `true`)
- `create_kms_endpoint` (bool, default `false`)
- `additional_interface_services` (list(string), default EKS-management baseline)
  - Default value:
    - `["eks", "sts", "ecr.api", "ecr.dkr", "ec2", "elasticloadbalancing", "autoscaling"]`
  - Override with a custom list when your environment needs fewer or more services.
- `create_s3_gateway_endpoint` (bool, default `true`)
- `s3_gateway_route_table_ids` (list(string), default `[]`)
  - When empty, route tables are inferred from `subnet_ids`.
  - Set explicitly when jump-host subnets use different route tables than endpoint subnets.
- `tags` (map(string))

## Outputs

- `endpoint_ids`
- `endpoint_dns_names`
- `created_security_group_ids`
- `s3_gateway_endpoint_id`
