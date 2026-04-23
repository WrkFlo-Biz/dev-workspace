#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC_DIR="${REPO_ROOT}/config/systemd-user"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LOG_DIR="${DWS_LOG_DIR:-/var/log/dws}"
MODE="${1:-install}"
UNITS=(
  dws-sessions-init.service
  dws-task-monitor.service
)

usage() {
  cat <<'EOF'
usage: dws-systemd-user-setup.sh [install|check|show]

Installs or verifies the repo-managed dev-workspace user services:
  - dws-sessions-init.service
  - dws-task-monitor.service
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

note() {
  printf '%s\n' "$*"
}

need_systemd_user() {
  have systemctl || {
    printf 'systemctl is required\n' >&2
    exit 1
  }
}

ensure_log_dir() {
  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    note "log dir ready: $LOG_DIR"
    return 0
  fi

  if [ -d "$LOG_DIR" ] && [ ! -w "$LOG_DIR" ]; then
    sudo -n chown "$USER:$(id -gn)" "$LOG_DIR"
    chmod 0775 "$LOG_DIR"
    note "updated log dir ownership: $LOG_DIR"
    return 0
  fi

  sudo -n install -d -o "$USER" -g "$(id -gn)" -m 0775 "$LOG_DIR"
  note "created log dir: $LOG_DIR"
}

install_units() {
  local unit

  mkdir -p "$DEST_DIR"
  ensure_log_dir

  for unit in "${UNITS[@]}"; do
    install -m 0644 "${SRC_DIR}/${unit}" "${DEST_DIR}/${unit}"
    note "installed ${DEST_DIR}/${unit}"
  done

  systemctl --user daemon-reload
  systemctl --user enable "${UNITS[@]}" >/dev/null
  note "enabled user units"
}

check_units() {
  local unit rc=0

  for unit in "${UNITS[@]}"; do
    if [ ! -f "${DEST_DIR}/${unit}" ]; then
      printf 'missing installed unit: %s\n' "${DEST_DIR}/${unit}" >&2
      rc=1
      continue
    fi

    if cmp -s "${SRC_DIR}/${unit}" "${DEST_DIR}/${unit}"; then
      note "ok ${unit}"
    else
      printf 'drift %s\n' "$unit" >&2
      rc=1
    fi
  done

  systemctl --user is-enabled "${UNITS[@]}" 2>/dev/null || rc=1
  return "$rc"
}

show_units() {
  local unit
  for unit in "${UNITS[@]}"; do
    printf '--- %s ---\n' "${SRC_DIR}/${unit}"
    sed -n '1,200p' "${SRC_DIR}/${unit}"
  done
}

main() {
  need_systemd_user

  case "$MODE" in
    install)
      install_units
      ;;
    check)
      check_units
      ;;
    show)
      show_units
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main
