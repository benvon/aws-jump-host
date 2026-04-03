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

# Alerting hooks (optional): v1 deployments typically only ship logs to this group. When you are ready to page
# on activity, set enable_session_log_metric_filters and session_log_alarm_actions. Further ideas: EventBridge
# rules on CloudTrail ssm:StartSession, metric filters for failed logins, or composite alarms for business hours.
locals {
  session_hook_suffix = replace(var.log_group_name, "/", "-")
}

resource "aws_cloudwatch_log_metric_filter" "session_sudo_hook" {
  count = var.enable_session_log_metric_filters ? 1 : 0

  name           = "${local.session_hook_suffix}-sudo-hook"
  log_group_name = aws_cloudwatch_log_group.session.name
  pattern        = var.session_log_sudo_metric_filter_pattern

  metric_transformation {
    name      = "JumpHostSessionSudoMentions"
    namespace = "JumpHost/SessionLogs"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "session_sudo_hook" {
  count = var.enable_session_log_metric_filters ? 1 : 0

  alarm_name          = "${local.session_hook_suffix}-sudo-hook"
  alarm_description   = "Starter hook: sudo-like substrings in session logs. Tune pattern; add SNS via session_log_alarm_actions."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "JumpHostSessionSudoMentions"
  namespace           = "JumpHost/SessionLogs"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.session_log_alarm_actions
  tags                = var.tags
}
