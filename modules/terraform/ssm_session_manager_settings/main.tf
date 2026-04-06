terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "default_host_management_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

locals {
  normalized_default_host_management_role_path = trim(var.default_host_management_role_path, "/")
  default_host_management_setting_value = coalesce(
    var.default_host_management_setting_value,
    local.normalized_default_host_management_role_path == ""
    ? var.default_host_management_role_name
    : "${local.normalized_default_host_management_role_path}/${var.default_host_management_role_name}"
  )

  # Note: inputs.runAsDefaultUser must be a literal string (or empty). AWS
  # rejects template placeholders such as {{runAsDefaultUser}} in Session
  # documents (InvalidDocumentContent). Per-session OS user selection is not
  # available via StartSession --parameters for Standard_Stream shell sessions;
  # use IAM principal tag SSMSessionRunAs and/or run_as_default_user here.
  session_manager_preferences = {
    schemaVersion = "1.0"
    description   = "Document to hold regional settings for Session Manager"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = false
      cloudWatchLogGroupName      = var.cloudwatch_log_group_name
      cloudWatchEncryptionEnabled = var.enable_cloudwatch_logging ? var.cloudwatch_encryption_enabled : false
      cloudWatchStreamingEnabled  = var.enable_cloudwatch_logging
      kmsKeyId                    = var.session_data_kms_key_id
      runAsEnabled                = var.enable_run_as
      runAsDefaultUser            = var.run_as_default_user
      idleSessionTimeout          = ""
      maxSessionDuration          = ""
      shellProfile = {
        windows = ""
        linux   = ""
      }
    }
  }

  session_access_document_names = distinct(compact(concat(
    [var.document_name],
    var.session_access_additional_document_names,
  )))
  session_access_document_arns = distinct(flatten([
    for document_name in local.session_access_document_names : [
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${document_name}",
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}::document/${document_name}",
    ]
  ]))

  session_access_role_mappings_by_arn = {
    for mapping in var.session_access_role_mappings :
    trimspace(mapping.role_arn) => {
      role_arn        = trimspace(mapping.role_arn)
      role_account_id = element(split(":", trimspace(mapping.role_arn)), 4)
      role_name = element(
        reverse(split("/", element(split("role/", trimspace(mapping.role_arn)), 1))),
        0
      )
      role_is_aws_reserved_sso = length(regexall(
        ":role/aws-reserved/sso.amazonaws.com/",
        trimspace(mapping.role_arn)
      )) > 0
      access_profile = trimspace(mapping.access_profile)
      linux_username = trimspace(mapping.linux_username)
    }
  }
}

data "aws_iam_policy_document" "session_access_role" {
  for_each = local.session_access_role_mappings_by_arn

  statement {
    sid    = "AllowStartSessionOnTaggedJumpHosts"
    effect = "Allow"
    actions = [
      "ssm:StartSession",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:managed-instance/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/JumpHost"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/AccessProfile"
      values   = [each.value.access_profile]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/AccessProfile"
      values   = [each.value.access_profile]
    }

    dynamic "condition" {
      for_each = var.session_access_enforce_run_as_principal_tag ? [1] : []

      content {
        test     = "StringEquals"
        variable = "aws:PrincipalTag/SSMSessionRunAs"
        values   = [each.value.linux_username]
      }
    }
  }

  statement {
    sid    = "AllowSessionDocumentUsage"
    effect = "Allow"
    actions = [
      "ssm:StartSession",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
    ]
    resources = local.session_access_document_arns
  }

  statement {
    sid    = "AllowResumeTerminateOwnSessions"
    effect = "Allow"
    actions = [
      "ssm:ResumeSession",
      "ssm:TerminateSession",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*",
    ]
  }

  statement {
    sid    = "AllowDescribeForSessionTargets"
    effect = "Allow"
    actions = [
      "ssm:DescribeInstanceInformation",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.session_access_kms_key_arn == null || trimspace(var.session_access_kms_key_arn) == "" ? [] : [1]

    content {
      sid    = "AllowSessionKmsUsage"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]
      resources = [trimspace(var.session_access_kms_key_arn)]
    }
  }
}

resource "aws_iam_role" "default_host_management" {
  count = var.enable_default_host_management && var.create_default_host_management_role ? 1 : 0

  name               = var.default_host_management_role_name
  path               = var.default_host_management_role_path
  assume_role_policy = data.aws_iam_policy_document.default_host_management_assume_role.json
}

resource "aws_iam_role_policy_attachment" "default_host_management_policy" {
  count = var.enable_default_host_management && var.create_default_host_management_role ? 1 : 0

  role       = aws_iam_role.default_host_management[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
}

resource "aws_ssm_service_setting" "default_host_management_role" {
  count = var.enable_default_host_management ? 1 : 0

  setting_id    = "/ssm/managed-instance/default-ec2-instance-management-role"
  setting_value = local.default_host_management_setting_value

  depends_on = [aws_iam_role_policy_attachment.default_host_management_policy]
}

resource "aws_ssm_document" "session_manager_preferences" {
  name            = var.document_name
  document_type   = "Session"
  document_format = "JSON"
  content         = jsonencode(local.session_manager_preferences)
}

resource "aws_iam_role_policy" "session_access_allowlist" {
  for_each = var.session_access_attach_role_policies ? local.session_access_role_mappings_by_arn : {}

  name   = var.session_access_policy_name
  role   = each.value.role_name
  policy = data.aws_iam_policy_document.session_access_role[each.key].json

  lifecycle {
    precondition {
      condition     = each.value.role_account_id == data.aws_caller_identity.current.account_id
      error_message = "session_access_role_mappings role_arn must reference roles in account ${data.aws_caller_identity.current.account_id}. Cross-account role ARNs are not supported."
    }

    precondition {
      condition     = !each.value.role_is_aws_reserved_sso
      error_message = "Cannot attach policy directly to AWSReservedSSO role ${each.value.role_name}. Set session_access_attach_role_policies=false and apply equivalent policy in the corresponding IAM Identity Center Permission Set."
    }
  }
}
