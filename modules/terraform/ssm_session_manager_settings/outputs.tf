output "service_settings" {
  description = "Configured Session Manager preferences."
  value = {
    document_name             = aws_ssm_document.session_manager_preferences.name
    document_version          = aws_ssm_document.session_manager_preferences.latest_version
    enable_run_as             = tostring(var.enable_run_as)
    enable_cloudwatch_logging = tostring(var.enable_cloudwatch_logging)
    cloudwatch_encryption     = tostring(var.enable_cloudwatch_logging && var.cloudwatch_encryption_enabled)
    cloudwatch_log_group_name = var.cloudwatch_log_group_name
    default_host_management = var.enable_default_host_management ? {
      setting_id    = aws_ssm_service_setting.default_host_management_role[0].setting_id
      setting_value = aws_ssm_service_setting.default_host_management_role[0].setting_value
    } : null
  }
}

output "session_access_allowlist" {
  description = "Allowlisted role mappings and applied inline policy attachments for SSM session access."
  value = {
    attach_role_policies = var.session_access_attach_role_policies
    policy_name          = var.session_access_policy_name
    document_names = sort(distinct(compact(concat(
      [var.document_name],
      var.session_access_additional_document_names,
    ))))
    mappings = [
      for role_arn in sort(keys(local.session_access_role_mappings_by_arn)) : {
        role_arn       = role_arn
        role_name      = local.session_access_role_mappings_by_arn[role_arn].role_name
        access_profile = local.session_access_role_mappings_by_arn[role_arn].access_profile
        linux_username = local.session_access_role_mappings_by_arn[role_arn].linux_username
      }
    ]
    attached_role_policies = sort([
      for role_arn in keys(aws_iam_role_policy.session_access_allowlist) :
      aws_iam_role_policy.session_access_allowlist[role_arn].role
    ])
    policy_documents_by_role_arn = {
      for role_arn in sort(keys(data.aws_iam_policy_document.session_access_role)) :
      role_arn => jsondecode(data.aws_iam_policy_document.session_access_role[role_arn].json)
    }
  }
}
