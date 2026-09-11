include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

locals {
  users_file = try(find_in_parent_folders("ansible/users.yaml"), "")
  users      = local.users_file != "" ? try(yamldecode(file(local.users_file)).users, []) : []
  downloader_role_arns = distinct(flatten([
    for user in local.users : try(user.iam_role_arns, [])
  ]))
}

dependency "jump_hosts" {
  config_path = "../jump-hosts"

  mock_outputs_allowed_in_commands = ["validate", "plan"]
  mock_outputs = {
    instance_role_arn  = "arn:aws:iam::111111111111:role/mock-jump-instance"
    instance_role_name = "mock-jump-instance"
  }
}

terraform {
  source = "../../../../../../modules/terraform/log_transfer"
}

inputs = {
  bucket_name          = "jh-log-${include.root.locals.account_id}-${include.root.locals.env}-${include.root.locals.subenv}-${include.root.locals.aws_region}"
  instance_role_arn    = dependency.jump_hosts.outputs.instance_role_arn
  instance_role_name   = dependency.jump_hosts.outputs.instance_role_name
  downloader_role_arns = local.downloader_role_arns
  retention_days       = 730
  tags = merge(include.root.locals.common_tags, {
    Component = "log-transfer"
  })
}
