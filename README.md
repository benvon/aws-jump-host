# aws-jump-host

Turn-key solution for deploying and managing private AWS jump hosts through AWS Session Manager.

## What This Provides

- Terraform modules for jump hosts, VPC endpoints, observability, and remote state bucket provisioning.
- Terragrunt orchestration for multi-environment structures (`env/subenv/region`).
- Ansible roles/playbooks for declarative host hardening and user provisioning over SSM.
- Shell orchestration for `init|plan|apply|check|destroy` workflows.
- CI workflows and local Make targets for validation parity.

## Security Defaults

- IMDSv2-only EC2 metadata configuration.
- No SSH ingress requirement.
- No local password or SSH-key auth provisioning by default.
- Least-privilege instance role for SSM agent functions.
- Session logging dependencies provisioned in CloudWatch.
- External IAM Identity Center controls integrated via deterministic host tags.

## Quick References

- [Architecture](docs/architecture.md)
- [Consumer Guide](docs/consumer-guide.md)
- [Access Model](docs/access-model.md)
- [Toolchain Policy](docs/toolchain.md)

## Local Validation

- `make fmt-check`
- `make lint`
- `make validate`
- `make check`

## Example Orchestration

```bash
./scripts/orchestrate.sh plan \
  --live-dir ./examples/live \
  --env dev \
  --subenv east \
  --region us-east-1 \
  --users-vars ./ansible/vars-schema.example.yml
```
