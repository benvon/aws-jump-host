# Toolchain Policy

This repository follows major-version compatibility ranges (not strict patch pinning).

## Supported Ranges

- Terraform: >= 1.10 (required for native S3 state locking via `use_lockfile = true`; no strict patch pinning above this floor)
- Terragrunt: 0.55.x - 0.68.x
- Ansible Core: >=2.15,<2.18
- Python: 3.10+

CI and local checks validate behavior across this expected range where practical.
