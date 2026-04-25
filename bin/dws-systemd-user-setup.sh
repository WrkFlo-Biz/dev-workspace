#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC_DIR="${REPO_ROOT}/config/systemd-user"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LOG_DIR="${DWS_LOG_DIR:-/var/log/dws}"
MODE="${1:-install}"
INSTALLED_UNITS=(
  dws-sessions-init.service
  dws-safe-mode.service
)
ENABLED_UNITS=(dws-sessions-init.service)
DISABLED_UNITS=(dws-safe-mode.service)
RETIRED_UNITS=(dws-task-monitor.service)

usage() {
  cat <<'EOF'
usage: dws-systemd-user-setup.sh [install|check|show]

Installs or verifies the repo-managed dev-workspace user services:
  - dws-sessions-init.service
  - dws-safe-mode.service (installed, disabled by default)

Retires the legacy repo-owned unit:
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

  for unit in "${INSTALLED_UNITS[@]}"; do
    install -m 0644 "${SRC_DIR}/${unit}" "${DEST_DIR}/${unit}"
    note "installed ${DEST_DIR}/${unit}"
  done

  for unit in "${RETIRED_UNITS[@]}"; do
    if [ -e "${DEST_DIR}/${unit}" ]; then
      rm -f -- "${DEST_DIR}/${unit}"
      note "removed stale installed unit ${DEST_DIR}/${unit}"
    fi
  done

  systemctl --user daemon-reload
  systemctl --user enable "${ENABLED_UNITS[@]}" >/dev/null
  note "enabled user units: ${ENABLED_UNITS[*]}"

  for unit in "${DISABLED_UNITS[@]}" "${RETIRED_UNITS[@]}"; do
    systemctl --user disable "$unit" >/dev/null 2>&1 || true
  done
  note "disabled optional or retired units: ${DISABLED_UNITS[*]} ${RETIRED_UNITS[*]}"
}

check_units() {
  local unit rc=0 state

  for unit in "${INSTALLED_UNITS[@]}"; do
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

  for unit in "${RETIRED_UNITS[@]}"; do
    if [ -e "${DEST_DIR}/${unit}" ]; then
      printf 'stale installed unit: %s\n' "${DEST_DIR}/${unit}" >&2
      rc=1
    fi
  done

  systemctl --user is-enabled "${ENABLED_UNITS[@]}" 2>/dev/null || rc=1

  for unit in "${DISABLED_UNITS[@]}"; do
    state=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    case "$state" in
      disabled|masked|indirect|static) ;;
      *)
        printf 'expected disabled optional unit, got %s for %s\n' "${state:-unknown}" "$unit" >&2
        rc=1
        ;;
    esac
  done

  for unit in "${RETIRED_UNITS[@]}"; do
    state=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    case "$state" in
      ''|not-found|disabled|masked|indirect|static|generated|linked|linked-runtime|transient) ;;
      *)
        printf 'expected retired unit to be disabled or absent, got %s for %s\n' "${state:-unknown}" "$unit" >&2
        rc=1
        ;;
    esac
  done

  return "$rc"
}

show_units() {
  local unit
  for unit in "${INSTALLED_UNITS[@]}"; do
    printf '--- %s ---\n' "${SRC_DIR}/${unit}"
    sed -n '1,200p' "${SRC_DIR}/${unit}"
  done
  printf '\nretired repo-owned units:\n'
  printf ' - %s\n' "${RETIRED_UNITS[@]}"
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
