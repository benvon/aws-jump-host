output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group used for session logging."
  value       = aws_cloudwatch_log_group.session.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group used for session logging."
  value       = aws_cloudwatch_log_group.session.arn
}

output "kms_key_arn" {
  description = "KMS key ARN used by the log group, either existing or created."
  value       = local.effective_kms_key_arn
}

output "session_sudo_metric_alarm_arn" {
  description = "ARN of the optional session log sudo-hook alarm (null when enable_session_log_metric_filters is false)."
  value       = try(aws_cloudwatch_metric_alarm.session_sudo_hook[0].arn, null)
}
