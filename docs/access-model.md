# Access Model

## Ownership Boundaries

- IAM Identity Center groups and assignments are externally managed.
- Session Manager account preferences are externally managed.
- This repository emits deterministic tags and policy templates to integrate with those controls.

## Enforcement Goals

- Host-level tags for access profile and run-as defaults.
- Session logging requirements validated via preflight checks.
- No direct mutation of centralized IAM Identity Center configuration.
