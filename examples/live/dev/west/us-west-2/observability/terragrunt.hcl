include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

terraform {
  source = "../../../../../../modules/terraform/observability"
}

inputs = {
  log_group_name = "/aws/ssm/jump-host/${include.root.locals.env}/${include.root.locals.subenv}/${include.root.locals.aws_region}"
  retention_days = 365
  tags = merge(include.root.locals.common_tags, {
    Component = "observability"
  })
}
