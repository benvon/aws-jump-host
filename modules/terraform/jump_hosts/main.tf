terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_ssm_parameter" "al2023_ami" {
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
      security_group_ids  = try(host.security_group_ids, [])
      instance_type       = try(host.instance_type, "t3.micro")
      root_volume_size_gb = try(host.root_volume_size_gb, 20)
      home_volume_size_gb = try(host.home_volume_size_gb, 20)
      tags                = try(host.tags, {})
    })
  }

  default_sg_hosts = {
    for host_name, host in local.normalized_hosts : host_name => host
    if length(host.security_group_ids) == 0
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

data "aws_iam_policy_document" "ssm_core" {
  statement {
    sid = "SsmManagedInstanceUpdate"

    actions = ["ssm:UpdateInstanceInformation"]

    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:*:*:managed-instance/*"
    ]
  }

  statement {
    sid = "SsmMessageChannels"

    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ssmmessages:*:*:control-channel/*",
      "arn:${data.aws_partition.current.partition}:ssmmessages:*:*:data-channel/*",
    ]
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

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2messages:*:*:endpoint/*",
      "arn:${data.aws_partition.current.partition}:ec2messages:*:*:message/*",
      "arn:${data.aws_partition.current.partition}:ec2messages:*:*:queue/*",
    ]
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
  for_each = local.default_sg_hosts

  name_prefix = "${var.name_prefix}-${each.key}-"
  description = "Restrictive default security group for jump host ${each.key}"
  vpc_id      = each.value.vpc_id

  egress {
    description = "Allow HTTPS egress for SSM and AWS API access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, each.value.tags, {
    Name = "${var.name_prefix}-${each.key}-default"
  })
}

resource "aws_instance" "host" {
  for_each = local.normalized_hosts

  ami                         = coalesce(try(each.value.ami_id, null), data.aws_ssm_parameter.al2023_ami.value)
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
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(var.common_tags, each.value.tags, {
    Name             = "${var.name_prefix}-${each.key}"
    JumpHost         = "true"
    AccessProfile    = each.value.access_profile
    RunAsDefaultUser = each.value.run_as_default_user
    ManagedBy        = "terraform"
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
