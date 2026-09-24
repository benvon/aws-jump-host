# Jump-host AWS session isolation for shared Run As users (ec2-user).
# Installed as /etc/profile.d/jump-host-aws-session.sh
# Also sourced from /etc/jump-host-ssm-bashrc (SSM bash --rcfile) so Session Manager
# sessions get JUMP_HOST_AWS_HOME even when profile.d timing is unreliable.
# shellcheck shell=bash
# SC2317: return||exit is intentional — profile.d is sourced; exit covers accidental direct run.
# shellcheck disable=SC2317

# Only interactive shells (SSM uses bash -i / --rcfile … -i). Skip noninteractive
# so bash -lc / ssh -t automation keeps durable ~/.aws credential lookup.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

_jh_aws_user="$(id -un 2>/dev/null || true)"
if [[ "$_jh_aws_user" != ec2-user ]]; then
  unset _jh_aws_user
  return 0 2>/dev/null || exit 0
fi

# SSM occasionally starts bash before pam/sshd has exported HOME. Resolve it.
# shellProfile may already have cd'd to / when HOME was unset; land in real HOME.
if [[ -z "${HOME:-}" ]]; then
  _jh_aws_pw="$(getent passwd "$_jh_aws_user" 2>/dev/null || true)"
  HOME="$(printf '%s' "$_jh_aws_pw" | cut -d: -f6)"
  unset _jh_aws_pw
  if [[ -z "$HOME" ]]; then
    unset _jh_aws_user
    return 0 2>/dev/null || exit 0
  fi
  export HOME
  cd "$HOME" 2>/dev/null || true
fi
unset _jh_aws_user

# Already initialized in this shell (nested source).
if [[ -n "${JUMP_HOST_AWS_HOME:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Tighten creation mode for the session tree only; restore afterward (this file is sourced).
_jh_aws_old_umask="$(umask)"
umask 077

_jh_aws_root="${HOME}/.cache/jump-host-aws"
if ! mkdir -p "$_jh_aws_root"; then
  umask "$_jh_aws_old_umask"
  unset _jh_aws_root _jh_aws_old_umask
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
  umask "$_jh_aws_old_umask"
  unset _jh_aws_root _jh_aws_session_id _jh_aws_home _jh_aws_old_umask
  return 0 2>/dev/null || exit 0
fi
if ! chmod 700 "$_jh_aws_home"; then
  rm -rf "$_jh_aws_home" 2>/dev/null || true
  umask "$_jh_aws_old_umask"
  unset _jh_aws_root _jh_aws_session_id _jh_aws_home _jh_aws_old_umask
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

umask "$_jh_aws_old_umask"
unset _jh_aws_old_umask

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
