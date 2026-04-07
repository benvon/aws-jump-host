# jump_hosts module

Provisions private EC2 jump hosts with IMDSv2-only metadata configuration, least-privilege SSM instance role, and dedicated persistent `/home` EBS volumes.

## Inputs

- `hosts` (map object): host definitions keyed by host name.
  - Per host, set one of:
    - `ami_id`: explicit pinned AMI ID.
    - `ami_ssm_parameter_name`: SSM parameter name that resolves to the latest AMI at apply time (for example `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`).
  - If neither is set, the module falls back to latest AL2023 x86_64.
- `name_prefix` (string): default `jump-host`.
- `common_tags` (map(string)): tags applied to all resources.
- `volume_kms_key_id` (string|null): optional KMS key for EBS encryption.
- `restrict_egress` (bool): default `false`. The module always allows outbound TCP/443 to the host's VPC primary CIDR so that SSM, EC2Messages, and SSMMessages VPC interface endpoints remain reachable. When `false`, an additional unrestricted TCP/443 rule (to `0.0.0.0/0`) is also applied. When `true`, only the rules in `egress_rules` are applied beyond the SSM baseline.
- `egress_rules` (list of objects): additional explicit egress rules applied when `restrict_egress` is `true`. Each object requires `from_port`, `to_port`, `protocol`, and `cidr_blocks`; `description` is optional. The SSM baseline (TCP/443 to VPC CIDR) is always active and does not need to be included here.

### Egress behaviour

| `restrict_egress` | `egress_rules` | Result |
|---|---|---|
| `false` (default) | — | SSM VPC CIDR baseline + TCP/443 → `0.0.0.0/0` |
| `true` | `[]` | SSM VPC CIDR baseline only (all other outbound denied) |
| `true` | `[...]` | SSM VPC CIDR baseline + caller-supplied rules |

### Example – restrict egress to VPC only (SSM + custom rules)

```hcl
module "jump_hosts" {
  source = "..."

  restrict_egress = true
  egress_rules = [
    {
      description = "Allow HTTPS to shared services VPC via peering"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["10.1.0.0/16"]
    },
  ]
  # ...
}
```

> **Note:** The SSM baseline rule (TCP/443 to the host's VPC primary CIDR) is always applied
> automatically, even when `restrict_egress = true` and `egress_rules = []`, to ensure SSM
> Session Manager connectivity is never broken by the egress setting.

Home EBS volumes are separate resources from instances, so replacing an instance reattaches the same volume when state is unchanged. Terraform does **not** allow `lifecycle.prevent_destroy` to be driven by a variable (it must be a literal), so this module does not expose a toggle for that. To hard-block destroys, add your own wrapper resource or organization guardrails (for example AWS Backup, SCPs, or a forked copy of this module with `lifecycle { prevent_destroy = true }` as a fixed literal on `aws_ebs_volume.home`).

## Outputs

- `hosts`: metadata map containing instance IDs, private IPs, AZ, and home volume IDs.
- `created_security_group_ids`: SG IDs created when host SGs were not supplied.
- `instance_profile_arn`: IAM profile ARN attached to instances.
