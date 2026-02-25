# jump_hosts module

Provisions private EC2 jump hosts with IMDSv2-only metadata configuration, least-privilege SSM instance role, and dedicated persistent `/home` EBS volumes.

## Inputs

- `hosts` (map object): host definitions keyed by host name.
- `name_prefix` (string): default `jump-host`.
- `common_tags` (map(string)): tags applied to all resources.
- `volume_kms_key_id` (string|null): optional KMS key for EBS encryption.

## Outputs

- `hosts`: metadata map containing instance IDs, private IPs, AZ, and home volume IDs.
- `created_security_group_ids`: SG IDs created when host SGs were not supplied.
- `instance_profile_arn`: IAM profile ARN attached to instances.
