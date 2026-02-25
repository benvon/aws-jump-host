# Consumer Guide

## Intent

Use this repository as a reusable orchestration layer while keeping environment-specific variables in a separate repository.

## Integration Model

1. Reference Terraform modules from this repo.
2. Reference Terragrunt root patterns from this repo.
3. Store live environment inputs externally.
4. Invoke this repo's orchestration scripts with the external live directory.

## Status

Detailed onboarding and usage examples are added in later iterations.
