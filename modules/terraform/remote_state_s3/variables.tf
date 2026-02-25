variable "state_bucket_name" {
  description = "Name of the S3 bucket used for Terraform state."
  type        = string
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for state bucket encryption. If null, SSE-S3 is used."
  type        = string
  default     = null
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
