# aws-jump-host

Turn-key solution for deploying and managing private AWS jump hosts through AWS Session Manager.

## What This Provides

- Terraform modules for jump hosts, VPC endpoints, observability, Session Manager settings, and remote state bucket provisioning.
- Terragrunt orchestration for multi-environment structures (`env/subenv/region`).
- Ansible roles/playbooks for declarative host hardening and user provisioning over SSM.
- Shell orchestration for `init|plan|apply|check|destroy` workflows.
- CI workflows and local Make targets for validation parity.

## Security Defaults

- IMDSv2-only EC2 metadata configuration.
- No SSH ingress requirement.
- No local password or SSH-key auth provisioning by default.
- The jump-host EC2 instance is intentionally without significant IAM role privileges. The instance role exists only so the host can run the SSM agent and so operators can start interactive Session Manager sessions. Operators bring their own IAM Identity Center (or IAM) credentials into the session for all environment work, including `log-transfer`; the instance profile is not a fallback principal.
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
- `make ci-validate-local` (mirrors `.github/workflows/validate.yml`)
- `make ci-check-local` (mirrors `.github/workflows/check.yml`)
- `make ci-local` (runs both workflow-equivalent targets)

## Example Orchestration

Run `plan` from the repository root (paths to scripts and generated inventory are rooted automatically):

```bash
./scripts/orchestrate.sh plan \
  --live-dir ./examples/live \
  --env dev \
  --subenv east \
  --region us-east-1 \
  --users-vars ./ansible/vars-schema.example.yml
```

plan and configure require an already-applied observability stack, compliant Session Manager preferences, the expected CloudWatch log group, and existing log-transfer outputs. A new account uses apply first. Use apply --ssm-self-management when this account must create the Session Manager preferences. --ssm-self-management on plan only adds a read-only plan of that stack.

`apply`, `configure`, and `destroy` prompt on a terminal by default. CD passes `--non-interactive`. You can also use `make apply-example-auto` / `make destroy-example-auto` for the bundled examples.

`make validate` runs `./scripts/orchestrate.sh validate`.
