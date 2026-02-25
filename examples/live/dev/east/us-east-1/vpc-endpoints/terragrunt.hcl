include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

locals {
  region_config = read_terragrunt_config(find_in_parent_folders("region.hcl"))
}

terraform {
  source = "../../../../../../modules/terraform/vpc_endpoints_ssm"
}

inputs = {
  vpc_id             = local.region_config.locals.vpc_id
  subnet_ids         = local.region_config.locals.endpoint_subnet_ids
  security_group_ids = local.region_config.locals.endpoint_security_group_ids
  tags = merge(include.root.locals.common_tags, {
    Component = "vpc-endpoints"
  })
}
