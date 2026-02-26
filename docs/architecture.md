# Architecture

## Overview

This repository composes four layers:

1. Terraform modules for reusable AWS primitives.
2. Terragrunt for environment orchestration and backend wiring.
3. Ansible for declarative host configuration over SSM transport.
4. Shell orchestration for repeatable operator workflows.

The resulting platform provisions private jump hosts reachable through AWS Session Manager (`aws ssm start-session`) with no SSH ingress requirement.

## Security Baseline

- EC2 metadata service requires IMDSv2 tokens.
- Instance IAM role is scoped to SSM agent operations and does not include broad administrative actions.
- Session logging is expected in CloudWatch and validated pre-apply.
- Access control remains centrally managed in IAM Identity Center, integrated via deterministic instance tags.
- Local user accounts have locked passwords and no SSH key provisioning by default.

## Component Boundaries

### Terraform modules

- `modules/terraform/jump_hosts`: EC2 hosts, instance profile, optional default SG, and persistent `/home` EBS volumes.
- `modules/terraform/vpc_endpoints_ssm`: shared interface endpoints for private SSM and CloudWatch connectivity.
- `modules/terraform/observability`: CloudWatch log group and optional KMS key.
- `modules/terraform/remote_state_s3`: encrypted versioned S3 state bucket.

### Terragrunt

- Canonical hierarchy: `<live-root>/<env>/<subenv>/<region>/<stack>`.
- Root config in `terragrunt/root.hcl` provides provider generation, assume-role wiring, common tags, and backend configuration.
- Example stacks under `examples/live/` are reference blueprints and should be copied into an external inputs repo.

### Ansible

- Playbook: `ansible/playbooks/jump_hosts.yml`.
- Roles:
  - `home_volume`: detect, format (if needed), and mount dedicated `/home` volume.
  - `base_hardening`: disable password/public-key SSH auth and enforce baseline packages.
  - `user_accounts`: authoritative user reconciliation using external vars schema.

### Shell orchestration

- `scripts/orchestrate.sh` orchestrates `init|plan|apply|configure|check|destroy`.
- `scripts/preflight_ssm_compliance.sh` validates required external Session Manager service settings.
- `scripts/render_inventory.sh` renders static inventory from Terragrunt outputs for Ansible over SSM.

## Data Flow

1. Terragrunt provisions state bucket (bootstrap) and infrastructure stacks.
2. Terraform outputs host metadata map.
3. Inventory renderer converts outputs to Ansible inventory keyed by EC2 instance ID.
4. Ansible connects via `aws_ssm` and converges host state.
5. Preflight checks gate plan/apply/configure on centralized SSM settings compliance.

## Operational Notes

- Backend locking is S3-only by design in this repository. Coordinate concurrent applies operationally.
- Destroy defaults to preserving bootstrap state bucket unless `--destroy-state` is explicitly passed.
- Production environment inputs are expected to live outside this repository.
