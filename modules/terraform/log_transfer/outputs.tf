output "bucket_name" {
  description = "Log-transfer S3 bucket name."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "Log-transfer S3 bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "region" {
  description = "AWS region of the log-transfer bucket."
  value       = data.aws_region.current.id
}
