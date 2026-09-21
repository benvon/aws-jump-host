# Jump-host AWS session isolation for shared Run As users (ec2-user).
# Installed as /etc/profile.d/jump-host-aws-session.sh
# shellcheck shell=bash

# Only interactive shells; avoid breaking scp/non-interactive.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

_jh_aws_user="$(id -un 2>/dev/null || true)"
if [[ "$_jh_aws_user" != ec2-user ]]; then
  unset _jh_aws_user
  return 0 2>/dev/null || exit 0
fi
unset _jh_aws_user

# Already initialized in this shell (nested source).
if [[ -n "${JUMP_HOST_AWS_HOME:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -z "${HOME:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_jh_aws_root="${HOME}/.cache/jump-host-aws"
mkdir -p "$_jh_aws_root"
# Session id: prefer uuidgen, else od from /dev/urandom.
if command -v uuidgen >/dev/null 2>&1; then
  JUMP_HOST_AWS_SESSION_ID="$(uuidgen | tr 'A-F' 'a-f')"
else
  JUMP_HOST_AWS_SESSION_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
fi
export JUMP_HOST_AWS_SESSION_ID
JUMP_HOST_AWS_HOME="${_jh_aws_root}/${JUMP_HOST_AWS_SESSION_ID}"
export JUMP_HOST_AWS_HOME
mkdir -p "${JUMP_HOST_AWS_HOME}/.aws/sso/cache"
chmod 700 "$JUMP_HOST_AWS_HOME"

if [[ -r "${HOME}/.aws/config" ]]; then
  cp "${HOME}/.aws/config" "${JUMP_HOST_AWS_HOME}/.aws/config"
  chmod 600 "${JUMP_HOST_AWS_HOME}/.aws/config"
else
  : >"${JUMP_HOST_AWS_HOME}/.aws/config"
  chmod 600 "${JUMP_HOST_AWS_HOME}/.aws/config"
fi
: >"${JUMP_HOST_AWS_HOME}/.aws/credentials"
chmod 600 "${JUMP_HOST_AWS_HOME}/.aws/credentials"

export AWS_CONFIG_FILE="${JUMP_HOST_AWS_HOME}/.aws/config"
export AWS_SHARED_CREDENTIALS_FILE="${JUMP_HOST_AWS_HOME}/.aws/credentials"

_jh_aws_cleanup() {
  local home="${JUMP_HOST_AWS_HOME:-}"
  local root="${HOME}/.cache/jump-host-aws"
  [[ -n "$home" ]] || return 0
  case "$home" in
    "${root}"/*) rm -rf "$home" ;;
  esac
}
trap _jh_aws_cleanup EXIT

unset _jh_aws_root
