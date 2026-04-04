locals {
  account_id       = "111111111111"
  assume_role_name = "OrganizationAccountAccessRole"
  state_bucket     = "aws-jump-host-dev-state"
  # Optional: merged into provider default_tags and all module tag maps (see docs/consumer-guide.md).
  # extra_tags = { CostCenter = "example" }
}
