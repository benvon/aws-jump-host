# ssm_session_manager_settings module

Manages AWS Systems Manager Session Manager account-level preferences via the `SSM-SessionManagerRunShell` Session document.

## Inputs

- `enable_run_as` (bool, default `true`)
- `enable_cloudwatch_logging` (bool, default `true`; controls `cloudWatchStreamingEnabled` in the Session document)
- `cloudwatch_encryption_enabled` (bool, default `true`; requires the target log group to be KMS-encrypted)
- `cloudwatch_log_group_name` (string, default `/aws/ssm/session-manager`)
- `session_data_kms_key_id` (string, default `alias/aws/ssm`; used for `inputs.kmsKeyId` in Session Manager preferences)
- `run_as_default_user` (string, default `""`; set this when `enable_run_as=true` unless you are using IAM principal tag `SSMSessionRunAs`; must be literal—AWS does not support per-session overrides via `StartSession` parameters for `runAsDefaultUser` in shell Session documents)
- `linux_shell_profile` (string|null, default `null`): `inputs.shellProfile.linux` for Standard_Stream sessions (POSIX `sh`, max **512** characters). `null` defaults to `cd "$HOME"; exec /bin/bash -i` so sessions land in the Run As user’s home and load **bash** interactively (which pulls in `/etc/bashrc` → `/etc/profile.d` on Amazon Linux 2023, including managed PS1). Login-only `bash -l` is **not** used here—it tended to drop Standard_Stream sessions. Set to `""` to keep stock `/bin/sh` if you must troubleshoot Ansible `aws_ssm` issues.
- `document_name` (string, default `SSM-SessionManagerRunShell`)
- `enable_default_host_management` (bool, default `true`)
- `create_default_host_management_role` (bool, default `true`)
- `default_host_management_role_name` (string, default `AWSSystemsManagerDefaultEC2InstanceManagementRole`)
- `default_host_management_role_path` (string, default `/service-role/`)
- `default_host_management_setting_value` (string|null, default `null`; if null, derived from role path/name)
- `session_access_role_mappings` (list(object), default `[]`; allowlisted role mappings `{ role_arn, access_profile, linux_username }`)
- `session_access_policy_name` (string, default `jump-host-ssm-access`; inline policy name attached to each allowlisted role)
- `session_access_enforce_run_as_principal_tag` (bool, default `true`; enforce `aws:PrincipalTag/SSMSessionRunAs == linux_username`)
- `session_access_attach_role_policies` (bool, default `true`; set `false` for `AWSReservedSSO_*` roles and apply policy in Identity Center Permission Set instead)
- `session_access_kms_key_arn` (string|null, default `null`; optional KMS key permissions for session encryption)
- `session_access_additional_document_names` (list(string), default `AWS-StartInteractiveCommand`, `AWS-StartPortForwardingSession`, `AWS-StartPortForwardingSessionToRemoteHost`)

## Managed resource

- SSM Session document: `SSM-SessionManagerRunShell` (or custom `document_name`)
- Optional IAM role + policy attachment for Default Host Management
- Optional SSM service setting: `/ssm/managed-instance/default-ec2-instance-management-role`
- Optional per-role inline IAM allowlist policies for Session Manager access (`aws_iam_role_policy`)

## Outputs

- `service_settings`
- `session_access_allowlist`

## Session access allowlist behavior

When `session_access_role_mappings` is non-empty, the module attaches one inline policy per listed role ARN. The policy allows Session Manager access only when:

- target is tagged `JumpHost=true`
- target `AccessProfile` tag equals mapped `access_profile`
- principal tag `AccessProfile` equals mapped `access_profile`
- principal tag `SSMSessionRunAs` equals mapped `linux_username` (when `session_access_enforce_run_as_principal_tag=true`)

The role ARN must be in the same account as the stack because inline policies are attached directly to IAM role names in-account.

If role ARNs are `AWSReservedSSO_*` (path `/aws-reserved/sso.amazonaws.com/...`), IAM will reject direct attachment. Set `session_access_attach_role_policies=false`; then consume `session_access_allowlist.policy_documents_by_role_arn` and apply equivalent statements in the corresponding IAM Identity Center Permission Set.

For session documents, the module grants both account-local document ARNs and AWS-managed document ARNs in the current region so tools like Ansible (`AWS-StartInteractiveCommand`) work without extra policy edits.
