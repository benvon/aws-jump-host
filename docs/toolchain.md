# Toolchain Policy

This repository follows major-version compatibility ranges (not strict patch pinning).

## Supported Ranges

- Terraform: ~> 1.10 (required for native S3 state locking via `use_lockfile = true`; allows any 1.x that satisfies the constraint)
- AWS provider (modules): ~> 6.0
- Terragrunt: 1.1.x (pinned in `.tool-versions` and `.github/actions/ci-setup`; same minor as local/CI). 1.1 enables Content-Addressable Storage (CAS) by default for module/config downloads.
- Ansible Core: >=2.15,<2.18
- Python: 3.10+

CI and local checks validate behavior across this expected range where practical.
