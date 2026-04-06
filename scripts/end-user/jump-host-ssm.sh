#!/usr/bin/env bash
# End-user helper: SSO login reminder, Session Manager plugin check, and jump host
# discovery by tags (default: JumpHost=true, running). Distribute this script to
# operators; they need AWS CLI v2 and the Session Manager plugin installed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  jump-host-ssm.sh doctor [--profile NAME] [--region REGION]
  jump-host-ssm.sh login  [--profile NAME]
  jump-host-ssm.sh list   [--profile NAME] [--region REGION]
                          [--tag KEY=VALUE ...] [--name-contains SUBSTRING]
  jump-host-ssm.sh connect [--profile NAME] [--region REGION]
                          [--instance-id i-...]
                          [--tag KEY=VALUE ...] [--name-contains SUBSTRING]
                          [--document-name SSM_DOC]

Environment:
  AWS_PROFILE, AWS_REGION / AWS_DEFAULT_REGION — same semantics as AWS CLI.

Defaults:
  list/connect require instances with tag JumpHost=true and state running.
  Additional --tag filters are ANDed (EC2 tag filters).

Run As (Linux user on the instance):
  AWS does not support choosing the OS user via StartSession --parameters for
  the standard shell Session document; use IAM tag SSMSessionRunAs (or IdP
  session tags) or the account default in Session Manager preferences. See
  docs/jump-host-end-user-guide.md.

Examples:
  export AWS_PROFILE=your-sso-profile
  export AWS_REGION=us-west-2
  ./jump-host-ssm.sh doctor
  ./jump-host-ssm.sh login
  ./jump-host-ssm.sh list --tag Environment=stage --name-contains core
  ./jump-host-ssm.sh connect --tag Environment=stage --name-contains core
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

aws_cli() {
  local -a args=()
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    args+=(--profile "${AWS_PROFILE}")
  fi
  if [[ -n "${region:-}" ]]; then
    args+=(--region "${region}")
  fi
  aws "${args[@]}" "$@"
}

caller_identity() {
  aws_cli sts get-caller-identity >/dev/null 2>&1
}

is_sso_profile() {
  local p="${AWS_PROFILE:-}"
  [[ -n "$p" ]] || return 1
  local url
  url="$(aws configure get sso_start_url --profile "$p" 2>/dev/null || true)"
  [[ -n "$url" ]]
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
}

require_session_manager_plugin() {
  command -v session-manager-plugin >/dev/null 2>&1 ||
    die "Session Manager plugin not found. Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
}

resolve_region() {
  region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -z "$region" ]]; then
    region="$(aws configure get region --profile "${AWS_PROFILE:-default}" 2>/dev/null || true)"
  fi
  [[ -n "$region" ]] || die "Set AWS_REGION (or pass --region) for this account."
}

cmd_doctor() {
  require_aws
  require_session_manager_plugin
  echo "AWS CLI: $(aws --version 2>&1)"
  echo "Session Manager plugin: $(command -v session-manager-plugin)"
  if ! caller_identity; then
    echo "AWS credentials: not valid for this profile/region."
    if is_sso_profile; then
      echo "Try: aws sso login --profile ${AWS_PROFILE}"
    else
      echo "Configure credentials for profile ${AWS_PROFILE:-default} (environment, SSO, or keys)."
    fi
    exit 1
  fi
  echo "AWS identity:"
  aws_cli sts get-caller-identity
  echo "OK: ready for SSM Session Manager."
}

cmd_login() {
  require_aws
  [[ -n "${AWS_PROFILE:-}" ]] || die "Set AWS_PROFILE to your SSO profile before login."
  if is_sso_profile; then
    aws sso login --profile "${AWS_PROFILE}"
  else
    die "Profile '${AWS_PROFILE}' has no sso_start_url. Use a named SSO profile or obtain credentials another way."
  fi
  caller_identity || die "Login finished but sts get-caller-identity still failed."
  echo "OK: SSO login succeeded."
}

build_filters() {
  jump_filters=(
    "Name=tag:JumpHost,Values=true"
    "Name=instance-state-name,Values=running"
  )
  local pair key val
  for pair in "${extra_tag_pairs[@]}"; do
    [[ "$pair" == *"="* ]] || die "Invalid --tag (expected KEY=VALUE): $pair"
    key="${pair%%=*}"
    val="${pair#*=}"
    [[ -n "$key" && -n "$val" ]] || die "Invalid --tag (empty key or value): $pair"
    jump_filters+=("Name=tag:${key},Values=${val}")
  done
}

list_instance_lines() {
  build_filters
  # Use a list projection (not an object): --output text sorts object keys alphabetically,
  # which reorders columns and breaks parsing (e.g. AZ was read as instance id).
  aws_cli ec2 describe-instances \
    --filters "${jump_filters[@]}" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,Placement.AvailabilityZone]' \
    --output text
}

read_instance_row() {
  local line="$1"
  IFS=$'\t' read -r id name az <<<"${line}" || true
}

cmd_list() {
  require_aws
  resolve_region
  caller_identity || die "Not logged in. Run: $0 login   (SSO) or refresh credentials."
  local -a lines=()
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    lines+=("${line}")
  done < <(list_instance_lines || true)

  local -a filtered=()
  local id name az
  for line in "${lines[@]}"; do
    read_instance_row "${line}"
    [[ -n "${id:-}" ]] || continue
    if [[ -n "${name_contains:-}" ]]; then
      [[ "${name:-}" == *"${name_contains}"* ]] || continue
    fi
    filtered+=("${line}")
  done
  if [[ ${#filtered[@]} -eq 0 ]]; then
    if [[ ${#extra_tag_pairs[@]} -gt 0 ]]; then
      echo "No matching running jump hosts (JumpHost=true with given --tag filters)."
    else
      echo "No matching running jump hosts (JumpHost=true)."
    fi
    exit 0
  fi
  printf '%-22s %-50s %s\n' "INSTANCE_ID" "NAME_TAG" "AZ"
  for line in "${filtered[@]}"; do
    read_instance_row "${line}"
    printf '%-22s %-50s %s\n' "$id" "${name:-}" "${az:-}"
  done
}

pick_instance_id() {
  require_aws
  resolve_region
  caller_identity || die "Not logged in. Run: $0 login   (SSO) or refresh credentials."
  require_session_manager_plugin

  if [[ -n "${instance_id:-}" ]]; then
    echo "${instance_id}"
    return
  fi

  local -a lines=()
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    lines+=("${line}")
  done < <(list_instance_lines || true)

  local -a ids=()
  local id name az
  for line in "${lines[@]}"; do
    read_instance_row "${line}"
    [[ -n "${id:-}" ]] || continue
    if [[ -n "${name_contains:-}" ]]; then
      [[ "${name:-}" == *"${name_contains}"* ]] || continue
    fi
    ids+=("$id")
  done

  if [[ ${#ids[@]} -eq 0 ]]; then
    die "No matching running jump hosts. Narrow filters with --tag or check your account/region."
  fi
  if [[ ${#ids[@]} -gt 1 ]]; then
    echo "Multiple jump hosts match; choose one with --instance-id or narrow --tag / --name-contains:" >&2
    name_contains=""
    cmd_list >&2
    exit 2
  fi
  local chosen="${ids[0]}"
  [[ "${chosen}" =~ ^i-[0-9a-fA-F]+$ ]] || die "Could not parse instance id from EC2 output (got '${chosen}'). Try --instance-id."
  echo "${chosen}"
}

cmd_connect() {
  local target
  require_aws
  resolve_region
  target="$(pick_instance_id)"
  echo "Starting SSM session to ${target} (region ${region})..."
  local -a sess=(ssm start-session --target "${target}")
  if [[ -n "${session_document:-}" ]]; then
    sess+=(--document-name "${session_document}")
  fi
  aws_cli "${sess[@]}"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 1
}
shift || true

region=""
instance_id=""
name_contains=""
session_document=""
tag_arg=""
declare -a extra_tag_pairs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      export AWS_PROFILE="${2:-}"
      [[ -n "$AWS_PROFILE" ]] || die "--profile requires a value"
      shift 2
      ;;
    --region)
      region="${2:-}"
      [[ -n "$region" ]] || die "--region requires a value"
      export AWS_REGION="$region"
      shift 2
      ;;
    --instance-id)
      instance_id="${2:-}"
      [[ -n "$instance_id" ]] || die "--instance-id requires a value"
      shift 2
      ;;
    --tag)
      tag_arg="${2:-}"
      [[ -n "${tag_arg}" ]] || die "--tag requires KEY=VALUE"
      extra_tag_pairs+=("${tag_arg}")
      shift 2
      ;;
    --name-contains)
      name_contains="${2:-}"
      [[ -n "$name_contains" ]] || die "--name-contains requires a value"
      shift 2
      ;;
    --document-name)
      session_document="${2:-}"
      [[ -n "$session_document" ]] || die "--document-name requires a value"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$cmd" in
  doctor) cmd_doctor ;;
  login) cmd_login ;;
  list) cmd_list ;;
  connect) cmd_connect ;;
  help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac
