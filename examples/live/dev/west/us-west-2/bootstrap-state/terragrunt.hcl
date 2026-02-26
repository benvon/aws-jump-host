include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

locals {
  account_config = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

terraform {
  source = "../../../../../../modules/terraform/remote_state_s3"
}

inputs = {
  state_bucket_name = local.account_config.locals.state_bucket
  tags = merge(include.root.locals.common_tags, {
    Component = "remote-state"
  })
}
