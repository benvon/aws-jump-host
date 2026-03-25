locals {
  env_config     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  subenv_config  = read_terragrunt_config(find_in_parent_folders("subenv.hcl"))
  region_config  = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  account_config = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  env              = local.env_config.locals.env
  subenv           = local.subenv_config.locals.subenv
  aws_region       = local.region_config.locals.aws_region
  account_id       = local.account_config.locals.account_id
  assume_role_name = local.account_config.locals.assume_role_name
  state_bucket     = local.account_config.locals.state_bucket
  is_bootstrap     = basename(get_terragrunt_dir()) == "bootstrap-state"

  common_tags = {
    Project        = "aws-jump-host"
    Environment    = local.env
    SubEnvironment = local.subenv
    Region         = local.aws_region
    ManagedBy      = "terragrunt"
  }
}

terraform_version_constraint = ">= 1.10"

remote_state {
  backend      = "s3"
  disable_init = local.is_bootstrap

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket       = local.state_bucket
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true
  }
}

generate "provider" {
  path      = "provider_generated.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF_PROVIDER
provider "aws" {
  region = "${local.aws_region}"

  assume_role {
    role_arn = "arn:aws:iam::${local.account_id}:role/${local.assume_role_name}"
  }

  default_tags {
    tags = ${jsonencode(local.common_tags)}
  }
}
EOF_PROVIDER
}

inputs = {
  common_tags     = local.common_tags
  environment     = local.env
  sub_environment = local.subenv
  aws_region      = local.aws_region
  target_account  = local.account_id
}
