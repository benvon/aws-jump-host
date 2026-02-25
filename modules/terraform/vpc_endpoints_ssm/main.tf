terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_region" "current" {}

locals {
  endpoint_services = toset(concat(
    ["ssm", "ssmmessages", "ec2messages", "logs"],
    var.create_kms_endpoint ? ["kms"] : []
  ))
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.endpoint_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = var.security_group_ids
  private_dns_enabled = var.private_dns_enabled

  tags = merge(var.tags, {
    Name      = "jump-host-${each.key}-endpoint"
    Service   = each.key
    ManagedBy = "terraform"
  })
}
