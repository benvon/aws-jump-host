# jump_hosts module

Provisions private EC2 jump hosts with IMDSv2-only metadata configuration, least-privilege SSM instance role, and dedicated persistent `/home` EBS volumes.

## Inputs

- `hosts` (map object): host definitions keyed by host name.
- `name_prefix` (string): default `jump-host`.
- `common_tags` (map(string)): tags applied to all resources.
- `volume_kms_key_id` (string|null): optional KMS key for EBS encryption.
- `restrict_egress` (bool): default `false`. When `false`, the module-created default security group allows outbound TCP/443 to `0.0.0.0/0`. When `true`, only the rules in `egress_rules` are used for outbound traffic; an empty `egress_rules` list results in **no outbound access**.
- `egress_rules` (list of objects): explicit egress rules used when `restrict_egress` is `true`. Each object requires `from_port`, `to_port`, `protocol`, and `cidr_blocks`; `description` is optional.

### Example – restrict egress to VPC endpoints only

```hcl
module "jump_hosts" {
  source = "..."

  restrict_egress = true
  egress_rules = [
    {
      description = "SSM VPC endpoint"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["10.0.1.10/32"]
    },
  ]
  # ...
}
```

### Example – deny all outbound (rely entirely on VPC interface endpoints)

```hcl
module "jump_hosts" {
  source = "..."

  restrict_egress = true
  egress_rules    = []
  # ...
}
```

## Outputs

- `hosts`: metadata map containing instance IDs, private IPs, AZ, and home volume IDs.
- `created_security_group_ids`: SG IDs created when host SGs were not supplied.
- `instance_profile_arn`: IAM profile ARN attached to instances.
