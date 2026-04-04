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

variable "enable_session_log_metric_filters" {
  description = <<-EOT
    When true, create a starter CloudWatch Logs metric filter and alarm on the session log group.
    Defaults to false: initial deployments rely on log delivery only; enable when you add SNS or other alarm_actions.
  EOT
  type        = bool
  default     = false
}

variable "session_log_alarm_actions" {
  description = "Alarm action ARNs (typically SNS topics) when the session log metric alarm fires. May be empty for a silent hook."
  type        = list(string)
  default     = []
}

variable "session_log_sudo_metric_filter_pattern" {
  description = "Logs metric filter pattern for the starter hook (tune to match SSM session transcript format)."
  type        = string
  default     = "?sudo"
}
