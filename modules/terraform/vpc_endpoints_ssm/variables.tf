variable "vpc_id" {
  description = "VPC ID where endpoints are created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for interface endpoints."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups applied to interface endpoints."
  type        = list(string)
}

variable "private_dns_enabled" {
  description = "Whether to enable private DNS for endpoints."
  type        = bool
  default     = true
}

variable "create_kms_endpoint" {
  description = "Whether to create a KMS interface endpoint."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to endpoint resources."
  type        = map(string)
  default     = {}
}
