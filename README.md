# aws-jump-host

Turn-key solution for deploying and managing private AWS jump hosts accessed through AWS Systems Manager Session Manager.

## Goals

- No SSH ingress from the public internet.
- No pre-provisioned SSH keys.
- IMDSv2-only EC2 instances.
- Least-privilege instance IAM role.
- Session logging to CloudWatch.
- Declarative infrastructure and host configuration.

## Stack

- Terraform modules for AWS resources.
- Terragrunt for multi-environment orchestration and remote state configuration.
- Ansible for host hardening and user lifecycle.
- Shell orchestration for end-to-end workflows.

## Repository Model

This repository is intentionally modular. It can be used as:

1. A standalone orchestration repo with provided `examples/live` references.
2. A shared module/orchestration repo consumed by a separate environment-input repo.

## Next Steps

See:

- `docs/architecture.md`
- `docs/consumer-guide.md`
- `docs/access-model.md`
- `docs/toolchain.md`
