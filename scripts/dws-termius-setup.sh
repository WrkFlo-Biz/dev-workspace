#!/usr/bin/env bash
set -euo pipefail

HOST_LABEL="${DWS_TERMIUS_HOST_LABEL:-Dev Workspace VM}"
HOSTNAME_VALUE="${DWS_TERMIUS_HOSTNAME:-100.117.16.63}"
PORT_VALUE="${DWS_TERMIUS_PORT:-22}"
USERNAME_VALUE="${DWS_TERMIUS_USERNAME:-moses}"

expand_home() {
  local path="${1:-}"
  if [ "${path#\~}" != "$path" ]; then
    path="${HOME}${path#\~}"
  fi
  printf '%s\n' "$path"
}

resolve_key_path() {
  local candidate

  if [ -n "${DWS_TERMIUS_KEY_PATH:-}" ]; then
    expand_home "$DWS_TERMIUS_KEY_PATH"
    return 0
  fi

  for candidate in \
    "${HOME}/.ssh/termius_20260415" \
    "${HOME}/.ssh/id_ed25519" \
    "${HOME}/.ssh/id_rsa"
  do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "${HOME}/.ssh/id_ed25519"
}

key_status() {
  if [ -f "$1" ]; then
    printf 'present'
  else
    printf 'missing'
  fi
}

main() {
  local ssh_key_path ssh_key_state

  ssh_key_path=$(resolve_key_path)
  ssh_key_state=$(key_status "$ssh_key_path")

  cat <<EOF
Termius host configuration
  Label: ${HOST_LABEL}
  Hostname: ${HOSTNAME_VALUE}
  Port: ${PORT_VALUE}
  Username: ${USERNAME_VALUE}
  Authentication: SSH key
  SSH key path: ${ssh_key_path} (${ssh_key_state})

Recommended Termius settings
  Mosh: Off
  SSH agent forwarding: Off
  Startup command: leave blank
  Keepalive interval: 30 seconds
  Terminal type: xterm-256color
  Character encoding: UTF-8
  Local echo: Off

Workflow notes
  Launcher: leave startup blank so the SSH login runs the dev-workspace launcher
  tmux prefix: Ctrl-a
  iPhone: use landscape mode when working in Codex or Claude
EOF
}

main "$@"
