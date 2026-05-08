terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_ssm_parameter" "al2023_ami_x86_64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_partition" "current" {}

data "aws_subnet" "host" {
  for_each = var.hosts
  id       = each.value.subnet_id
}

locals {
  normalized_hosts = {
    for host_name, host in var.hosts : host_name => merge(host, {
      security_group_ids     = try(host.security_group_ids, [])
      instance_type          = try(host.instance_type, "t3.micro")
      ami_ssm_parameter_name = try(host.ami_ssm_parameter_name, null)
      root_volume_size_gb    = try(host.root_volume_size_gb, 20)
      home_volume_size_gb    = try(host.home_volume_size_gb, 20)
      tags                   = try(host.tags, {})
    })
  }

  default_sg_hosts = {
    for host_name, host in local.normalized_hosts : host_name => host
    if length(host.security_group_ids) == 0
  }
}

data "aws_ssm_parameter" "host_ami" {
  for_each = {
    for host_name, host in local.normalized_hosts : host_name => host.ami_ssm_parameter_name
    if try(host.ami_id, null) == null && try(host.ami_ssm_parameter_name, null) != null
  }

  name = each.value
}

# Look up the VPC for every host that will receive a module-created default security group.
# The VPC primary CIDR is used to build the always-on SSM baseline egress rule so that
# Session Manager connectivity is preserved regardless of the restrict_egress setting.
data "aws_vpc" "host" {
  for_each = local.default_sg_hosts
  id       = each.value.vpc_id
}

locals {
  # Compute the full egress ruleset (per host) for the module-created default security group.
  #
  # The SSM baseline rule (TCP/443 to the host's VPC primary CIDR) is ALWAYS prepended so that
  # SSM Session Manager (ssm, ec2messages, ssmmessages VPC interface endpoints) remains reachable
  # even when restrict_egress is true and egress_rules is empty.
  #
  # When restrict_egress is false, an additional unrestricted TCP/443 rule is appended.
  # When restrict_egress is true, only the caller-supplied egress_rules are appended.
  default_sg_egress_rules = {
    for host_name, host in local.default_sg_hosts : host_name => concat(
      [
        {
          description = "Allow HTTPS to VPC CIDR for SSM, EC2Messages, and SSMMessages endpoints"
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = [data.aws_vpc.host[host_name].cidr_block]
        }
      ],
      var.restrict_egress ? var.egress_rules : [
        {
          description = "Allow HTTPS egress for SSM and AWS API access"
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      ]
    )
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid = "Ec2AssumeRole"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name_prefix        = "${var.name_prefix}-instance-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = var.common_tags
}

# tfsec:ignore:aws-iam-no-policy-wildcards ssmmessages and ec2messages do not support resource-level permissions; AWS Service Authorization Reference requires "Resource": "*".
data "aws_iam_policy_document" "ssm_core" {
  #checkov:skip=CKV_AWS_355:ssmmessages and ec2messages do not support resource-level permissions; AWS requires "Resource": "*" per Service Authorization Reference.
  #checkov:skip=CKV_AWS_356:ssmmessages and ec2messages do not support resource-level permissions; AWS requires "Resource": "*" per Service Authorization Reference.
  statement {
    sid = "SsmManagedInstanceUpdate"

    actions = ["ssm:UpdateInstanceInformation"]

    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:*:*:managed-instance/*"
    ]
  }

  # ssmmessages and ec2messages do not support resource-level permissions.
  # AWS Service Authorization Reference requires "Resource": "*" for both services.
  # See: https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonmessagegatewayservice.html
  # See: https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonmessagedeliveryservice.html
  statement {
    sid = "SsmMessageChannels"

    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]

    resources = ["*"]
  }

  statement {
    sid = "Ec2MessagesCore"

    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ssm_core" {
  name   = "${var.name_prefix}-ssm-core"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.ssm_core.json
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "${var.name_prefix}-profile-"
  role        = aws_iam_role.instance.name
  tags        = var.common_tags
}

resource "aws_security_group" "default" {
  # tfsec:ignore:aws-ec2-no-public-egress-sgr Accepted risk: when restrict_egress=false, outbound HTTPS to 0.0.0.0/0 is allowed for AWS API reachability; callers can set restrict_egress=true for stricter egress controls.
  #checkov:skip=CKV_AWS_382:Accepted risk: when restrict_egress=false, outbound HTTPS to 0.0.0.0/0 is allowed for AWS API reachability; callers can set restrict_egress=true.
  for_each = local.default_sg_hosts

  name_prefix = "${var.name_prefix}-${each.key}-"
  description = "Restrictive default security group for jump host ${each.key}"
  vpc_id      = each.value.vpc_id

  dynamic "egress" {
    for_each = local.default_sg_egress_rules[each.key]
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(var.common_tags, each.value.tags, {
    Name = "${var.name_prefix}-${each.key}-default"
  })
}

resource "aws_instance" "host" {
  for_each = local.normalized_hosts

  ami                         = coalesce(try(each.value.ami_id, null), try(data.aws_ssm_parameter.host_ami[each.key].value, null), data.aws_ssm_parameter.al2023_ami_x86_64.value)
  instance_type               = each.value.instance_type
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = length(each.value.security_group_ids) > 0 ? each.value.security_group_ids : [aws_security_group.default[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = false
  monitoring                  = true
  ebs_optimized               = true

  root_block_device {
    volume_size = each.value.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.volume_kms_key_id
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  tags = merge(var.common_tags, each.value.tags, {
    Name          = "${var.name_prefix}-${each.key}"
    JumpHost      = "true"
    AccessProfile = each.value.access_profile
    ManagedBy     = "terraform"
  })
}

resource "aws_ebs_volume" "home" {
  for_each = local.normalized_hosts

  availability_zone = data.aws_subnet.host[each.key].availability_zone
  size              = each.value.home_volume_size_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.volume_kms_key_id

  tags = merge(var.common_tags, each.value.tags, {
    Name      = "${var.name_prefix}-${each.key}-home"
    JumpHost  = "true"
    Component = "home-volume"
    HostName  = each.key
    ManagedBy = "terraform"
  })
}

resource "aws_volume_attachment" "home" {
  for_each = local.normalized_hosts

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.home[each.key].id
  instance_id = aws_instance.host[each.key].id

  stop_instance_before_detaching = true
}
