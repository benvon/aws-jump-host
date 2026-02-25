terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  effective_access_log_bucket_name = var.create_access_log_bucket ? coalesce(var.access_log_bucket_name, "${var.state_bucket_name}-access-logs") : var.access_log_bucket_name
  effective_access_log_prefix      = trim(var.access_log_prefix, "/")
}

#checkov:skip=CKV_AWS_18:This bucket is the dedicated destination for S3 access logs. Logging it would cause recursive log chains.
resource "aws_s3_bucket" "access_logs" { #tfsec:ignore:aws-s3-enable-bucket-logging This bucket is the dedicated destination for S3 access logs. Logging it would cause recursive log chains.
  count = var.create_access_log_bucket ? 1 : 0

  bucket = local.effective_access_log_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = var.create_access_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  count = var.create_access_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = var.create_access_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = var.create_access_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "expire-old-access-logs"
    status = "Enabled"

    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "access_logs" {
  count = var.create_access_log_bucket ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.access_logs[0].arn,
      "${aws_s3_bucket.access_logs[0].arn}/*"
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
      "${aws_s3_bucket.access_logs[0].arn}/${local.effective_access_log_prefix}/${var.state_bucket_name}/*"
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
  count = var.create_access_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  policy = data.aws_iam_policy_document.access_logs[0].json
}

resource "aws_s3_bucket" "state" {
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

resource "aws_s3_bucket_logging" "state" {
  bucket = aws_s3_bucket.state.id

  target_bucket = local.effective_access_log_bucket_name
  target_prefix = "${local.effective_access_log_prefix}/${var.state_bucket_name}/"

  depends_on = [aws_s3_bucket_policy.access_logs]
}

data "aws_iam_policy_document" "state_tls_only" {
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
