variable "log_group_name" {
  description = "CloudWatch log group name used for session logs."
  type        = string
}

variable "retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 365
}

variable "kms_key_arn" {
  description = "Existing KMS key ARN for CloudWatch log group encryption."
  type        = string
  default     = null
}

variable "create_kms_key" {
  description = "Whether to create a KMS key when kms_key_arn is not provided."
  type        = bool
  default     = true
}

variable "kms_alias_name" {
  description = "Alias for created KMS key."
  type        = string
  default     = "alias/jump-host-session-logs"
}

variable "tags" {
  description = "Tags to apply to created resources."
  type        = map(string)
  default     = {}
}
