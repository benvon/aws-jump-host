locals {
  env_config     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  subenv_config  = read_terragrunt_config(find_in_parent_folders("subenv.hcl"))
  region_config  = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  account_config = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  env              = local.env_config.locals.env
  subenv           = local.subenv_config.locals.subenv
  aws_region       = local.region_config.locals.aws_region
  account_id       = local.account_config.locals.account_id
  assume_role_name = lookup(local.account_config.locals, "assume_role_name", "")
  state_bucket     = local.account_config.locals.state_bucket

  # Optional assume_role provider fragment; empty when credentials already target the account directly.
  assume_role_fragment = local.assume_role_name != "" ? format(
    "  assume_role {\n    role_arn = \"arn:aws:iam::%s:role/%s\"\n  }\n\n",
    local.account_id,
    local.assume_role_name
  ) : ""

  # Base tags + optional extra_tags from live hierarchy (account → env → subenv; later wins on duplicate keys).
  # The generated AWS provider uses default_tags with this map so taggable resources inherit it automatically;
  # stacks also pass the same map into modules as common_tags / tags for explicit merges.
  common_tags = merge(
    {
      Project        = "aws-jump-host"
      Environment    = local.env
      SubEnvironment = local.subenv
      Region         = local.aws_region
      ManagedBy      = "terragrunt"
    },
    lookup(local.account_config.locals, "extra_tags", {}),
    lookup(local.env_config.locals, "extra_tags", {}),
    lookup(local.subenv_config.locals, "extra_tags", {})
  )
}

terraform_version_constraint = "~> 1.10"

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket = local.state_bucket
    # Include hierarchy may live outside the environment tree; strip "../" so S3 object
    # keys are always valid and deterministic.
    key          = "${replace(path_relative_to_include(), "../", "")}/terraform.tfstate"
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

${local.assume_role_fragment}

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
