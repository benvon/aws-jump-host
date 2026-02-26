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
data "aws_caller_identity" "current" {}

locals {
  effective_kms_key_arn = var.kms_key_arn != null ? var.kms_key_arn : (
    var.create_kms_key ? aws_kms_key.logs[0].arn : null
  )
}

data "aws_iam_policy_document" "kms" {
  count = var.kms_key_arn == null && var.create_kms_key ? 1 : 0

  statement {
    sid    = "RootAccountAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]

    resources = ["*"]
  }
}

resource "aws_kms_key" "logs" {
  count = var.kms_key_arn == null && var.create_kms_key ? 1 : 0

  description             = "KMS key for jump host session logs"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms[0].json
  tags                    = var.tags
}

resource "aws_kms_alias" "logs" {
  count = var.kms_key_arn == null && var.create_kms_key ? 1 : 0

  name          = var.kms_alias_name
  target_key_id = aws_kms_key.logs[0].key_id
}

resource "aws_cloudwatch_log_group" "session" {
  name              = var.log_group_name
  retention_in_days = var.retention_days
  kms_key_id        = local.effective_kms_key_arn
  tags              = var.tags
}
