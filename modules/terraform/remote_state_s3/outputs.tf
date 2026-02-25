output "state_bucket_name" {
  description = "Terraform state bucket name."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "Terraform state bucket ARN."
  value       = aws_s3_bucket.state.arn
}
