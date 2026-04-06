terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  effective_access_log_bucket_name = coalesce(var.access_log_bucket_name, "${var.state_bucket_name}-access-logs")
  effective_access_log_prefix      = trim(var.access_log_prefix, "/")
  ssm_transfer_object_arns = [
    for pattern in var.ssm_transfer_key_patterns : "${aws_s3_bucket.state.arn}/${pattern}"
  ]
  ssm_transfer_principals = var.ssm_transfer_principal_arns
  ssm_transfer_key_prefixes = [
    for pattern in var.ssm_transfer_key_patterns : split("/", pattern)[0]
  ]
}

resource "aws_s3_bucket" "access_logs" { #tfsec:ignore:aws-s3-enable-bucket-logging This bucket is the dedicated destination for S3 access logs. Logging it would cause recursive log chains. #tfsec:ignore:aws-s3-enable-versioning Versioning is configured via standalone aws_s3_bucket_versioning.
  #checkov:skip=CKV_AWS_18:This bucket is the dedicated destination for S3 access logs. Logging it would cause recursive log chains.
  #checkov:skip=CKV_AWS_21:Versioning is configured via a standalone aws_s3_bucket_versioning resource.
  #checkov:skip=CKV2_AWS_62:S3 event notifications are intentionally not configured for state/log buckets in this module.
  #checkov:skip=CKV_AWS_144:Cross-region replication is intentionally left to higher-level DR policies.
  bucket = local.effective_access_log_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" { #tfsec:ignore:aws-s3-encryption-customer-key Logging bucket is intentionally configured for AWS-managed KMS per platform requirement.
  #checkov:skip=CKV_AWS_145:Logging bucket is intentionally configured for AWS-managed KMS per platform requirement.
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-old-access-logs"
    status = "Enabled"

    expiration {
      days = var.access_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "access_logs" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.access_logs.arn,
      "${aws_s3_bucket.access_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowS3ServerAccessLogDelivery"
    effect = "Allow"

    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    resources = [
      "${aws_s3_bucket.access_logs.arn}/${local.effective_access_log_prefix}/${var.state_bucket_name}/*"
    ]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.state.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:S3 event notifications are intentionally not configured for state/log buckets in this module.
  #checkov:skip=CKV_AWS_144:Cross-region replication is intentionally left to higher-level DR policies.
  bucket        = var.state_bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "state" {
  bucket = aws_s3_bucket.state.id

  target_bucket = local.effective_access_log_bucket_name
  target_prefix = "${local.effective_access_log_prefix}/${var.state_bucket_name}/"

  depends_on = [aws_s3_bucket_policy.access_logs]
}

data "aws_iam_policy_document" "state_tls_only" {
  dynamic "statement" {
    for_each = var.enable_in_account_ssm_transfer_access ? [1] : []
    content {
      sid    = "AllowInAccountSsmTransferBucketDiscovery"
      effect = "Allow"

      actions = [
        "s3:GetBucketLocation",
        "s3:ListBucket",
      ]

      principals {
        type        = "AWS"
        identifiers = local.ssm_transfer_principals
      }

      resources = [aws_s3_bucket.state.arn]

      condition {
        test     = "StringLikeIfExists"
        variable = "s3:prefix"
        values   = local.ssm_transfer_key_prefixes
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_in_account_ssm_transfer_access ? [1] : []
    content {
      sid    = "AllowInAccountSsmTransferObjectOps"
      effect = "Allow"

      actions = [
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:PutObject",
      ]

      principals {
        type        = "AWS"
        identifiers = local.ssm_transfer_principals
      }

      resources = local.ssm_transfer_object_arns
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}
