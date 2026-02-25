variable "hosts" {
  description = "Map of jump host definitions keyed by logical host name."
  type = map(object({
    vpc_id              = string
    subnet_id           = string
    security_group_ids  = optional(list(string), [])
    instance_type       = optional(string, "t3.micro")
    ami_id              = optional(string)
    access_profile      = string
    run_as_default_user = string
    root_volume_size_gb = optional(number, 20)
    home_volume_size_gb = optional(number, 20)
    tags                = optional(map(string), {})
  }))
}

variable "name_prefix" {
  description = "Prefix used for resource naming."
  type        = string
  default     = "jump-host"
}

variable "common_tags" {
  description = "Tags applied to all resources in addition to per-host tags."
  type        = map(string)
  default     = {}
}

variable "volume_kms_key_id" {
  description = "Optional KMS key id/arn for EBS encryption."
  type        = string
  default     = null
}
