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

umask 077

_jh_aws_root="${HOME}/.cache/jump-host-aws"
if ! mkdir -p "$_jh_aws_root"; then
  unset _jh_aws_root
  return 0 2>/dev/null || exit 0
fi

# Session id: prefer uuidgen, else od from /dev/urandom.
if command -v uuidgen >/dev/null 2>&1; then
  _jh_aws_session_id="$(uuidgen | tr 'A-F' 'a-f')"
else
  _jh_aws_session_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
fi
_jh_aws_home="${_jh_aws_root}/${_jh_aws_session_id}"

# Create the session tree before exporting; on failure leave env unset.
if ! mkdir -p "${_jh_aws_home}/.aws/sso/cache"; then
  unset _jh_aws_root _jh_aws_session_id _jh_aws_home
  return 0 2>/dev/null || exit 0
fi
if ! chmod 700 "$_jh_aws_home"; then
  rm -rf "$_jh_aws_home" 2>/dev/null || true
  unset _jh_aws_root _jh_aws_session_id _jh_aws_home
  return 0 2>/dev/null || exit 0
fi

if [[ -r "${HOME}/.aws/config" ]]; then
  cp "${HOME}/.aws/config" "${_jh_aws_home}/.aws/config"
  chmod 600 "${_jh_aws_home}/.aws/config"
else
  : >"${_jh_aws_home}/.aws/config"
  chmod 600 "${_jh_aws_home}/.aws/config"
fi
: >"${_jh_aws_home}/.aws/credentials"
chmod 600 "${_jh_aws_home}/.aws/credentials"

export JUMP_HOST_AWS_SESSION_ID="$_jh_aws_session_id"
export JUMP_HOST_AWS_HOME="$_jh_aws_home"
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

unset _jh_aws_root _jh_aws_session_id _jh_aws_home
