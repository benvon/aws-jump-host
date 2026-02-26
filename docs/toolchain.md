# Toolchain Policy

This repository follows major-version compatibility ranges (not strict patch pinning).

## Supported Ranges

- Terraform: versions as defined in `.tool-versions` and CI workflows (major-version compatibility; no strict patch pinning)
- Terragrunt: 0.55.x - 0.68.x
- Ansible Core: >=2.15,<2.18
- Python: 3.10+

CI and local checks validate behavior across this expected range where practical.
