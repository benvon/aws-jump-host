variable "state_bucket_name" {
  description = "Name of the S3 bucket used for Terraform state."
  type        = string
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for state bucket encryption. If null, SSE-S3 is used."
  type        = string
  default     = null
}

variable "access_log_bucket_name" {
  description = "Optional managed access log bucket name. Defaults to <state_bucket_name>-access-logs."
  type        = string
  default     = null
}

variable "access_log_prefix" {
  description = "Prefix used for S3 server access logs."
  type        = string
  default     = "s3-access-logs"
}

variable "access_log_retention_days" {
  description = "Retention window for access log objects."
  type        = number
  default     = 365
}

variable "force_destroy" {
  description = "Whether to allow destroying a non-empty state bucket."
  type        = bool
  default     = false
}

variable "enable_in_account_ssm_transfer_access" {
  description = "When true, add state-bucket policy statements so explicitly allowed in-account principals can list the bucket and transfer objects for Ansible SSM."
  type        = bool
  default     = false
}

variable "ssm_transfer_key_patterns" {
  description = "Object-key glob patterns allowed for in-account SSM transfer access."
  type        = list(string)
  default = [
    "i-*/*",
    "mi-*/*"
  ]
}

variable "ssm_transfer_principal_arns" {
  description = "IAM principal ARNs (role/user) permitted to perform in-account SSM transfer operations on the state bucket."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_in_account_ssm_transfer_access || length(var.ssm_transfer_principal_arns) > 0
    error_message = "When enable_in_account_ssm_transfer_access is true, ssm_transfer_principal_arns must include at least one IAM principal ARN."
  }
}

variable "tags" {
  description = "Tags applied to state resources."
  type        = map(string)
  default     = {}
}
