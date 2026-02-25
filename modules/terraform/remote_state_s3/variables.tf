variable "state_bucket_name" {
  description = "Name of the S3 bucket used for Terraform state."
  type        = string
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for state bucket encryption. If null, SSE-S3 is used."
  type        = string
  default     = null
}

variable "create_access_log_bucket" {
  description = "Whether to create and manage a dedicated S3 access logging bucket."
  type        = bool
  default     = true
}

variable "access_log_bucket_name" {
  description = "Optional existing or managed access log bucket name. Required when create_access_log_bucket is false."
  type        = string
  default     = null

  validation {
    condition     = var.create_access_log_bucket || var.access_log_bucket_name != null
    error_message = "access_log_bucket_name must be set when create_access_log_bucket is false."
  }
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
