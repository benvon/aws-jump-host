variable "vpc_id" {
  description = "VPC ID where endpoints are created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for interface endpoints."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups applied to interface endpoints. If empty, module-managed endpoint security groups are created."
  type        = list(string)
  default     = []
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

variable "additional_interface_services" {
  description = "Additional AWS interface endpoint service suffixes."
  type        = list(string)
  default = [
    "eks",
    "sts",
    "ecr.api",
    "ecr.dkr",
    "ec2",
    "elasticloadbalancing",
    "autoscaling"
  ]
}

variable "create_s3_gateway_endpoint" {
  description = "Whether to create an S3 gateway endpoint for private S3 access (required for Ansible aws_ssm file transfer in private subnets without NAT)."
  type        = bool
  default     = true
}

variable "s3_gateway_route_table_ids" {
  description = "Route table IDs associated with the S3 gateway endpoint. If empty, route tables are inferred from subnet_ids."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to endpoint resources."
  type        = map(string)
  default     = {}
}
