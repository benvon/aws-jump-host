# AWS Security and User Provisioning Prerequisites

## Purpose

This document is the single handoff reference for prerequisites owned by AWS Security/IAM and Linux user-provisioning teams before operating this jump host platform.

## Scope and Ownership

### Security/IAM team owns

- IAM Identity Center groups, assignments, and permission sets
- Session Manager account-level service settings
- ABAC policy model for who can start sessions to which hosts
- CloudWatch log access controls and KMS key policy (when using existing CMKs)
- Network guardrails and endpoint policy standards

### User provisioning team owns

- Authoritative Linux user declarations consumed by Ansible
- Group/sudo intent for each user
- Lifecycle updates (add/remove/disable) in the external users vars file

### Platform repo owns

- Jump host infrastructure and tags (`JumpHost`, `AccessProfile`)
- IMDSv2-only enforcement and least-privilege instance role
- CloudWatch log group provisioning
- Ansible convergence over SSM
- Preflight validation of required Session Manager settings

## Required Prerequisites Checklist

1. Identity model and ABAC policy are in place.
2. Session Manager service settings are configured per region/account.
3. CloudWatch session log destination is configured and accessible.
4. Private connectivity path to SSM/Logs APIs exists (endpoints or approved egress).
5. Authoritative users vars file is prepared and maintained.

## 1) IAM Identity Center and ABAC Requirements

Use centralized IAM policies that allow sessions only to tagged jump hosts and only for approved access profiles.

Required instance tag contract emitted by this platform:

- `JumpHost=true`
- `AccessProfile=<profile>`

Recommended policy condition model:

- `ssm:resourceTag/JumpHost == true`
- `ssm:resourceTag/AccessProfile` matches `${aws:PrincipalTag/AccessProfile}`

Starter policy template:

- `policy-templates/ssm-access-example.json`

Required action families for operator access:

- `ssm:StartSession`, `ssm:ResumeSession`, `ssm:TerminateSession`
- `ssm:GetDocument`, `ssm:DescribeDocument`
- `ssm:DescribeInstanceInformation`
- `ec2:DescribeInstances`

## 2) Session Manager Service Settings (Per Account/Region)

These settings are required and are validated by preflight:

- `/ssm/sessionmanager/enableRunAs = true`
- `/ssm/sessionmanager/enableCloudWatchLogging = true`
- `/ssm/sessionmanager/cloudWatchLogGroupName = /aws/ssm/jump-host/<env>/<subenv>/<region>`

Validation command used by this repo:

- `scripts/preflight_ssm_compliance.sh --region <region> --expected-log-group <name>`

Notes:

- This platform does not set Session Manager account preferences; they must be set externally.
- This platform does not enforce principal-to-OS-user mapping in IAM. If you need strict mapping, enforce it centrally in IAM/session controls.

## 3) Logging and Encryption Prerequisites

- Session logs must be enabled to CloudWatch Logs (see service settings above).
- If using an existing customer-managed KMS key for the log group, key policy must allow the regional CloudWatch Logs service principal.
- Security team should define log read access boundaries and retention requirements.

## 4) Network Prerequisites

For private subnets without internet/NAT egress, provide VPC interface endpoints for:

- `ssm`
- `ssmmessages`
- `ec2messages`
- `logs`
- `kms` (if KMS API access is required)

This repo includes a module for this:

- `modules/terraform/vpc_endpoints_ssm`

If endpoints are not used, outbound HTTPS (`tcp/443`) to required AWS APIs must be permitted by policy.

## 5) Linux User Provisioning Prerequisites

Provide authoritative user declarations via external vars file using this schema:

- `users[]`
- `username` (required)
- `groups` (required list)
- `sudo_profile` (required: `none|ops|admin`)
- `state` (optional, default `present`)
- `shell` (optional, default `/bin/bash`)
- `home` (optional, default `/home/<username>`)

Reference file:

- `ansible/vars-schema.example.yml`

Platform behavior:

- Authoritative reconciliation for managed users (UID threshold and exclusions apply)
- Undeclared managed users are disabled/removed from groups
- Passwords remain locked
- SSH key auth is not provisioned by this platform

## 6) Operational Handoff Inputs Required From Security/User Teams

Provide the following to platform operators:

1. AccessProfile taxonomy and mapping to Identity Center groups/permission sets.
2. Confirmation that Session Manager settings are configured for each target account/region.
3. CloudWatch/KMS logging controls and approvals.
4. Approved user vars file location and change workflow owner.

## 7) Verification Before First Production Apply

1. Run preflight for target region/account.
2. Confirm operator can start an SSM session only to allowed `AccessProfile` hosts.
3. Confirm session log events appear in the expected CloudWatch log group.
4. Run `./scripts/orchestrate.sh configure ...` with users vars and confirm expected Linux account state.
