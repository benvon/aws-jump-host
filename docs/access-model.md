# Access Model

Primary handoff document for prerequisite ownership and setup:

- `docs/security-user-prerequisites.md`

## Responsibility Split

External platform/IAM team normally owns:

- IAM Identity Center groups and assignments
- Session Manager account-level preferences
- Permission boundaries/organization guardrails

Optional fallback when central management is unavailable:

- This repository can manage Session Manager preferences with the per-region `ssm-self-management` stack and `--ssm-self-management` orchestrator flag.
- The same stack can also attach inline allowlist policies to explicitly declared IAM roles for Session Manager access.

This repository owns:

- Host tags consumed by access policies (`JumpHost`, `AccessProfile`)
- Host build/configuration baseline
- Compliance preflight checks for required SSM settings
- Example policy templates for central IAM teams

## Jump-host instance role

The EC2 instance role is intentionally without significant privileges. It exists so the SSM agent can run and so operators can start interactive sessions. It is **not** used for S3, EKS, or other environment operations.

Operators bring their own IAM Identity Center (or IAM) credentials into the session. `log-transfer`, `awslogin`, and `kubelogin` use those credentials (`AWS_PROFILE` / exported keys), not the instance profile.

Operator-facing explanation (profiles, dual config, privilege model): `docs/jump-host-end-user-guide.md`.

## Tag Contract for IAM Conditions

Terraform applies these key tags on jump instances:

- `JumpHost=true`
- `AccessProfile=<profile>`

Central IAM policies can require principals to match host `AccessProfile` and restrict sessions to tagged jump hosts only.

## Session Manager Preconditions

Before `plan`/`apply`, preflight validates:

- Session preferences document `SSM-SessionManagerRunShell` exists
- `inputs.runAsEnabled=true`
- `inputs.cloudWatchLogGroupName` matches expected log group path

With `--ssm-self-management`, orchestrator applies the `ssm-self-management` stack before preflight so these settings are managed in-account and separately state-scoped.

## Example IAM Policy Artifacts

See `policy-templates/ssm-access-example.json` for a starter pattern that central IAM administrators can adapt.

## Notes on Run As

When role allowlist mappings are configured in `ssm-self-management`, this repository can enforce `aws:PrincipalTag/SSMSessionRunAs` and `aws:PrincipalTag/AccessProfile` in per-role inline policies.

The principal tag values still must be supplied by your identity/federation model (role tags and/or session tags).
