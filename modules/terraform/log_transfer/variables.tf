variable "bucket_name" {
  description = "Globally unique S3 bucket name for jump-host log archives."
  type        = string
}

variable "instance_role_arn" {
  description = "Jump host instance role ARN allowed to upload archives."
  type        = string
}

variable "instance_role_name" {
  description = "Jump host instance role name to attach the upload inline policy."
  type        = string
}

variable "downloader_role_arns" {
  description = "IAM role ARNs allowed to download via the AWS console (typically users[].iam_role_arns). Empty means uploads only."
  type        = list(string)
  default     = []
}

variable "retention_days" {
  description = "Expire log-transfer objects after this many days."
  type        = number
  default     = 730
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
