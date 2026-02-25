output "state_bucket_name" {
  description = "Terraform state bucket name."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "Terraform state bucket ARN."
  value       = aws_s3_bucket.state.arn
}

output "access_log_bucket_name" {
  description = "S3 bucket receiving access logs for the state bucket."
  value       = local.effective_access_log_bucket_name
}

output "access_log_bucket_arn" {
  description = "ARN of the access log bucket when managed by this module; null when external."
  value       = var.create_access_log_bucket ? aws_s3_bucket.access_logs[0].arn : null
}
