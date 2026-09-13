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
data "aws_caller_identity" "current" {}

locals {
  downloader_role_arns = distinct(compact(var.downloader_role_arns))

  # GetObject and ListBucket are intentional: operators may pull archives back
  # onto the shared jump host with instance-role credentials. Console download
  # still uses downloader_role_arns after SSO. Every local user shares this role.
  instance_upload_object_actions = [
    "s3:PutObject",
    "s3:GetObject",
    "s3:AbortMultipartUpload",
    "s3:ListMultipartUploadParts",
  ]

  instance_upload_bucket_actions = [
    "s3:ListBucket",
    "s3:GetBucketLocation",
    "s3:ListBucketMultipartUploads",
  ]
}

#tfsec:ignore:aws-s3-enable-bucket-logging Log-transfer archives do not use a separate S3 access-log bucket per design.
#tfsec:ignore:aws-s3-enable-versioning Versioning is intentionally not enabled for ephemeral log archives.
resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18:Log-transfer archives do not use a separate S3 access-log bucket per design.
  #checkov:skip=CKV_AWS_21:Versioning is intentionally not enabled for ephemeral log archives.
  #checkov:skip=CKV_AWS_145:Log-transfer buckets intentionally use SSE-S3 (AES256), not a customer-managed KMS key.
  #checkov:skip=CKV2_AWS_62:S3 event notifications are intentionally not configured for log-transfer buckets.
  #checkov:skip=CKV_AWS_144:Cross-region replication is intentionally not configured for log-transfer buckets.
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#tfsec:ignore:aws-s3-encryption-customer-key Log-transfer buckets intentionally use SSE-S3 (AES256), not a customer-managed KMS key.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  #checkov:skip=CKV_AWS_145:Log-transfer buckets intentionally use SSE-S3 (AES256), not a customer-managed KMS key.
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Provider 6.x requires at least one tiering block. Delayed ARCHIVE_ACCESS is at
# S3's max (730 days), matching default expiry so objects are not held in
# restore-required archive during retention.
resource "aws_s3_bucket_intelligent_tiering_configuration" "entire_bucket" {
  bucket = aws_s3_bucket.this.id
  name   = "entire-bucket"
  status = "Enabled"

  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = min(730, max(var.retention_days, 90))
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-log-archives"
    status = "Enabled"

    expiration {
      days = var.retention_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowInstanceUploadObjects"
    effect = "Allow"

    actions = local.instance_upload_object_actions

    principals {
      type        = "AWS"
      identifiers = [var.instance_role_arn]
    }

    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid    = "AllowInstanceUploadBucket"
    effect = "Allow"

    actions = local.instance_upload_bucket_actions

    principals {
      type        = "AWS"
      identifiers = [var.instance_role_arn]
    }

    resources = [aws_s3_bucket.this.arn]
  }

  dynamic "statement" {
    for_each = length(local.downloader_role_arns) > 0 ? [1] : []

    content {
      sid    = "AllowDownloaderGetObject"
      effect = "Allow"

      actions = ["s3:GetObject"]

      principals {
        type        = "AWS"
        identifiers = local.downloader_role_arns
      }

      resources = ["${aws_s3_bucket.this.arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.downloader_role_arns) > 0 ? [1] : []

    content {
      sid    = "AllowDownloaderBucketDiscovery"
      effect = "Allow"

      actions = [
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]

      principals {
        type        = "AWS"
        identifiers = local.downloader_role_arns
      }

      resources = [aws_s3_bucket.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

data "aws_iam_policy_document" "instance_upload" {
  statement {
    sid    = "AllowLogTransferUpload"
    effect = "Allow"

    actions = concat(
      local.instance_upload_object_actions,
      local.instance_upload_bucket_actions,
    )

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "upload" {
  name   = "log-transfer-upload"
  role   = var.instance_role_name
  policy = data.aws_iam_policy_document.instance_upload.json
}
