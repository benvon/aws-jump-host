include "root" {
  path   = "${get_terragrunt_dir()}/../../../../../../terragrunt/root.hcl"
  expose = true
}

locals {
  # orchestrate.sh always exports JUMP_HOST_ORCHESTRATE=1 and JUMP_HOST_USERS_VARS
  # (path or empty) so downloader ARNs match Ansible. Direct Terragrunt keeps the
  # ancestor ansible/users.yaml fallback when the env var is unset.
  users_file = (
    get_env("JUMP_HOST_ORCHESTRATE", "") == "1"
    ? get_env("JUMP_HOST_USERS_VARS", "")
    : get_env("JUMP_HOST_USERS_VARS", try(find_in_parent_folders("ansible/users.yaml"), ""))
  )
  # Fail closed with the Ansible user schema so a direct apply cannot grant
  # download ARNs for records Ansible would reject. Prefer JUMP_HOST_USERS_VALIDATOR
  # (orchestrate: shared checkout); otherwise this repository's copy.
  users_validator = get_env("JUMP_HOST_USERS_VALIDATOR", "${get_repo_root()}/scripts/validate_users_vars.py")
  users_schema    = local.users_file == "" ? "" : run_cmd("--terragrunt-quiet", local.users_validator, local.users_file)
  users_data      = local.users_file != "" ? yamldecode(file(local.users_file)) : {}
  users           = try(local.users_data.users, [])
  downloader_role_arns = distinct(flatten([
    for user in local.users :
    try(user.state, "present") == "absent" ? [] : try(user.iam_role_arns, [])
  ]))
}

dependency "jump_hosts" {
  config_path = "../jump-hosts"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
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
