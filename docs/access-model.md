# Access Model

## Responsibility Split

External platform/IAM team owns:

- IAM Identity Center groups and assignments
- Session Manager account-level preferences
- Permission boundaries/organization guardrails

This repository owns:

- Host tags consumed by access policies (`JumpHost`, `AccessProfile`)
- Host build/configuration baseline
- Compliance preflight checks for required SSM settings
- Example policy templates for central IAM teams

## Tag Contract for IAM Conditions

Terraform applies these key tags on jump instances:

- `JumpHost=true`
- `AccessProfile=<profile>`

Central IAM policies can require principals to match host `AccessProfile` and restrict sessions to tagged jump hosts only.

## Session Manager Preconditions

Before `plan`/`apply`, preflight validates:

- `/ssm/sessionmanager/enableRunAs=true`
- `/ssm/sessionmanager/enableCloudWatchLogging=true`
- `/ssm/sessionmanager/cloudWatchLogGroupName` matches expected log group path

## Example IAM Policy Artifacts

See `policy-templates/ssm-access-example.json` for a starter pattern that central IAM administrators can adapt.

## Notes on Run As

Run As restrictions are not configured by this repository. To enforce principal-to-RunAs mapping, use centralized IAM policies and Session Manager preference constraints in the access-management account.
