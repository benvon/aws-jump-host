terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_region" "current" {}

data "aws_vpc" "target" {
  id = var.vpc_id
}

locals {
  endpoint_services = toset(concat(
    ["ssm", "ssmmessages", "ec2messages", "logs"],
    var.create_kms_endpoint ? ["kms"] : [],
    var.additional_interface_services
  ))

  create_managed_security_groups = length(var.security_group_ids) == 0
}

data "aws_route_table" "endpoint_subnet" {
  for_each  = var.create_s3_gateway_endpoint && length(var.s3_gateway_route_table_ids) == 0 ? toset(var.subnet_ids) : toset([])
  subnet_id = each.value
}

locals {
  effective_s3_gateway_route_table_ids = var.create_s3_gateway_endpoint ? (
    length(var.s3_gateway_route_table_ids) > 0
    ? var.s3_gateway_route_table_ids
    : distinct([for _, rt in data.aws_route_table.endpoint_subnet : rt.id])
  ) : []
}

resource "aws_security_group" "endpoint" {
  #tfsec:ignore:aws-ec2-no-public-egress-sgr Accepted risk: Interface endpoint ENIs require outbound HTTPS reachability to AWS service backends; restricting egress to only VPC CIDR can break Session Manager connectivity.
  #checkov:skip=CKV2_AWS_5:False positive; this SG is attached in aws_vpc_endpoint.interface.security_group_ids when module-managed endpoint SGs are enabled.
  #checkov:skip=CKV_AWS_382:Accepted risk: Interface endpoint ENIs require outbound HTTPS to AWS service backends for PrivateLink control-plane/data-plane operations.
  for_each = local.create_managed_security_groups ? local.endpoint_services : toset([])

  name_prefix = "jump-host-${each.key}-vpce-"
  description = "Managed security group for ${each.key} interface endpoint"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.target.cidr_block]
  }

  egress {
    description = "Allow outbound HTTPS to AWS service backends"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-ec2-no-public-egress-sgr Accepted risk: Endpoint ENIs need outbound HTTPS for PrivateLink backend/service traffic; VPC-CIDR-only egress breaks SSM data/control paths.
  }

  tags = merge(var.tags, {
    Name      = "jump-host-${each.key}-endpoint-sg"
    Service   = each.key
    ManagedBy = "terraform"
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.endpoint_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.id}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = local.create_managed_security_groups ? [aws_security_group.endpoint[each.key].id] : var.security_group_ids
  private_dns_enabled = var.private_dns_enabled

  tags = merge(var.tags, {
    Name      = "jump-host-${each.key}-endpoint"
    Service   = each.key
    ManagedBy = "terraform"
  })
}

resource "aws_vpc_endpoint" "s3_gateway" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.id}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.effective_s3_gateway_route_table_ids

  tags = merge(var.tags, {
    Name      = "jump-host-s3-gateway-endpoint"
    Service   = "s3"
    ManagedBy = "terraform"
  })
}
