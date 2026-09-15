variable "bucket_name" {
  description = "Globally unique S3 bucket name for jump-host log archives."
  type        = string
}

variable "downloader_role_arns" {
  description = "IAM role ARNs allowed to upload and download log archives (typically users[].iam_role_arns). Empty means nobody can upload or download until ARNs are set."
  type        = list(string)
  default     = []
}

variable "retention_days" {
  description = "Expire log-transfer objects after this many days (1-730). Capped at 730 so Intelligent-Tiering ARCHIVE_ACCESS cannot outlive expiration."
  type        = number
  default     = 730

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 730
    error_message = "retention_days must be between 1 and 730 (S3 ARCHIVE_ACCESS maximum is 730 days)."
  }
}

variable "force_destroy" {
  description = "Allow destroying a non-empty log-transfer bucket."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
