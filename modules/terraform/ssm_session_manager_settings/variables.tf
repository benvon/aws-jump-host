variable "enable_run_as" {
  description = "Whether Session Manager Run As should be enabled."
  type        = bool
  default     = true
}

variable "enable_cloudwatch_logging" {
  description = "Whether Session Manager should enable CloudWatch log streaming in the Session document."
  type        = bool
  default     = true
}

variable "cloudwatch_encryption_enabled" {
  description = "Whether Session Manager requires CloudWatch log group encryption for session logging."
  type        = bool
  default     = true
}

variable "cloudwatch_log_group_name" {
  description = "CloudWatch log group name used by Session Manager preferences."
  type        = string
  default     = "/aws/ssm/session-manager"
}

variable "run_as_default_user" {
  description = "Optional default OS user for Session Manager Run As. Leave empty to rely on IAM principal tags (SSMSessionRunAs). Must be a literal value; AWS does not allow templating this field in Session documents."
  type        = string
  default     = ""
}

variable "linux_shell_profile" {
  description = "Session Manager inputs.shellProfile.linux (POSIX sh, max 512 characters). null uses the module default: cd to $HOME then exec interactive bash (-i) so profile.d PS1 snippets load on Amazon Linux. Set to \"\" for stock /bin/sh only (no automatic cd/bash)."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.linux_shell_profile == null ? true : length(var.linux_shell_profile) <= 512
    error_message = "linux_shell_profile must be at most 512 characters (AWS Session Manager limit)."
  }
}

variable "session_data_kms_key_id" {
  description = "KMS key ID/ARN/alias used by Session Manager document inputs.kmsKeyId for session data encryption. Defaults to AWS managed alias/aws/ssm."
  type        = string
  default     = "alias/aws/ssm"
}

variable "document_name" {
  description = "Session Manager preferences document name."
  type        = string
  default     = "SSM-SessionManagerRunShell"
}

variable "enable_default_host_management" {
  description = "Whether to configure Systems Manager Default Host Management for this account/region."
  type        = bool
  default     = true
}

variable "create_default_host_management_role" {
  description = "Whether to create and manage the IAM role used by Default Host Management."
  type        = bool
  default     = true
}

variable "default_host_management_role_name" {
  description = "IAM role name used by Systems Manager Default Host Management."
  type        = string
  default     = "AWSSystemsManagerDefaultEC2InstanceManagementRole"
}

variable "default_host_management_role_path" {
  description = "IAM role path used by Systems Manager Default Host Management."
  type        = string
  default     = "/service-role/"
}

variable "default_host_management_setting_value" {
  description = "Optional explicit value for /ssm/managed-instance/default-ec2-instance-management-role (for example service-role/RoleName). If null, derived from role path and name."
  type        = string
  default     = null
}

variable "session_access_role_mappings" {
  description = "Allowlisted IAM roles that may start SSM sessions on jump hosts, with required AccessProfile and RunAs username mapping."
  type = list(object({
    role_arn       = string
    access_profile = string
    linux_username = string
  }))
  default = []

  validation {
    condition = alltrue([
      for mapping in var.session_access_role_mappings :
      can(regex("^arn:[^:]+:iam::[0-9]{12}:role/.+$", trimspace(mapping.role_arn)))
    ])
    error_message = "Each session_access_role_mappings[*].role_arn must be a valid IAM role ARN."
  }

  validation {
    condition = alltrue([
      for mapping in var.session_access_role_mappings :
      trimspace(mapping.access_profile) != ""
    ])
    error_message = "Each session_access_role_mappings[*].access_profile must be non-empty."
  }

  validation {
    condition = alltrue([
      for mapping in var.session_access_role_mappings :
      can(regex("^[a-z_][a-z0-9_-]*[$]?$", trimspace(mapping.linux_username)))
    ])
    error_message = "Each session_access_role_mappings[*].linux_username must look like a valid Linux username."
  }

  validation {
    condition = length(var.session_access_role_mappings) == length(toset([
      for mapping in var.session_access_role_mappings :
      trimspace(mapping.role_arn)
    ]))
    error_message = "session_access_role_mappings must not contain duplicate role_arn entries."
  }
}

variable "session_access_policy_name" {
  description = "Inline IAM policy name attached to each allowlisted role."
  type        = string
  default     = "jump-host-ssm-access"
}

variable "session_access_enforce_run_as_principal_tag" {
  description = "When true, role policy enforces aws:PrincipalTag/SSMSessionRunAs == linux_username mapping."
  type        = bool
  default     = true
}

variable "session_access_attach_role_policies" {
  description = "Whether to attach generated allowlist policies directly to IAM roles in this account. Set false when using AWSReservedSSO_* roles, which are not modifiable via IAM APIs."
  type        = bool
  default     = true
}

variable "session_access_kms_key_arn" {
  description = "Optional CMK ARN used for Session Manager session encryption. When set, allowlisted roles also receive kms:Decrypt/GenerateDataKey/DescribeKey on this key."
  type        = string
  default     = null

  validation {
    condition     = var.session_access_kms_key_arn == null || trimspace(var.session_access_kms_key_arn) == "" || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key\\/.+$", trimspace(var.session_access_kms_key_arn)))
    error_message = "session_access_kms_key_arn must be null/empty or a valid KMS key ARN."
  }
}

variable "session_access_additional_document_names" {
  description = "Additional SSM Session document names that allowlisted roles may use for StartSession/GetDocument/DescribeDocument."
  type        = list(string)
  default = [
    "AWS-StartInteractiveCommand",
    "AWS-StartPortForwardingSession",
    "AWS-StartPortForwardingSessionToRemoteHost",
  ]
}
