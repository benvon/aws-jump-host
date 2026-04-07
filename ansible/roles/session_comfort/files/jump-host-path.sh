# Ansible managed — prepend ~/bin to PATH when the directory exists (idempotent).
if [ -n "${HOME:-}" ] && [ -d "${HOME}/bin" ]; then
  case ":${PATH}:" in
    *:"${HOME}/bin":*) ;;
    *) PATH="${HOME}/bin:${PATH}" ;;
  esac
  export PATH
fi
