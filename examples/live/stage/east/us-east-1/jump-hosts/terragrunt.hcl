include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

locals {
  region_config = read_terragrunt_config(find_in_parent_folders("region.hcl"))
}

dependencies {
  paths = ["../observability", "../vpc-endpoints"]
}

terraform {
  source = "../../../../../../modules/terraform/jump_hosts"
}

inputs = {
  name_prefix = "jump-${include.root.locals.env}-${include.root.locals.subenv}"

  hosts = {
    "core-01" = {
      vpc_id              = local.region_config.locals.vpc_id
      subnet_id           = local.region_config.locals.default_host_subnet_id
      security_group_ids  = []
      access_profile      = "ops"
      root_volume_size_gb = 20
      home_volume_size_gb = 50
      tags = {
        Role = "jump-host"
      }
    }
  }
}
