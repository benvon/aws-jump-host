variable "hosts" {
  description = "Map of jump host definitions keyed by logical host name."
  type = map(object({
    vpc_id              = string
    subnet_id           = string
    security_group_ids  = optional(list(string), [])
    instance_type       = optional(string, "t3.micro")
    ami_id              = optional(string)
    access_profile      = string
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

variable "restrict_egress" {
  description = "When true, the module-created default security group uses only the rules in `egress_rules` for outbound traffic (in addition to the always-applied SSM baseline that allows TCP/443 to the VPC CIDR). An empty `egress_rules` list with `restrict_egress = true` will allow only the SSM baseline. When false (default), outbound TCP/443 to 0.0.0.0/0 is allowed in addition to the SSM baseline."
  type        = bool
  default     = false
}

variable "egress_rules" {
  description = "Additional explicit egress rules applied to the module-created default security group when `restrict_egress` is true. Each rule requires `cidr_blocks`, `from_port`, `to_port`, and `protocol`. `description` is optional. The SSM baseline rule (TCP/443 to the VPC primary CIDR) is always applied automatically and does not need to be included here."
  type = list(object({
    description = optional(string, "")
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}
