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

variable "tags" {
  description = "Tags applied to state resources."
  type        = map(string)
  default     = {}
}
