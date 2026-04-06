include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

terraform {
  source = "../../../../../../modules/terraform/ssm_session_manager_settings"
}

inputs = {
  cloudwatch_log_group_name = "/aws/ssm/jump-host/${include.root.locals.env}/${include.root.locals.subenv}/${include.root.locals.aws_region}"
  enable_run_as             = true
  enable_cloudwatch_logging = true
}
