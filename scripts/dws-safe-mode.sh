#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

SAFE_MODE_FLAG="/tmp/dws-safe-mode.active"
CONTROL_PLANE_UNITS=(
  dws-sessions-init.service
  wrkflo-orchestrator-api.service
  dws-task-monitor.service
)

log() { printf "%s [safe-mode] %s\n" "$(date "+%H:%M:%S")" "$*"; }

unit_name() {
  case "${1:-}" in
    *.service) printf '%s\n' "$1" ;;
    *) printf '%s.service\n' "$1" ;;
  esac
}

unit_exists() {
  local unit load_state

  unit=$(unit_name "$1")
  load_state=$(systemctl --user show "$unit" --property=LoadState --value 2>/dev/null || true)
  case "$load_state" in
    ''|not-found) return 1 ;;
    *) return 0 ;;
  esac
}

unit_active_state() {
  local unit state

  unit=$(unit_name "$1")
  state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  state=$(printf '%s\n' "$state" | sed -n '1p')
  printf '%s\n' "${state:-stopped}"
}

stop_control_plane_units() {
  local unit

  for unit in "${CONTROL_PLANE_UNITS[@]}"; do
    if ! unit_exists "$unit"; then
      log "$(unit_name "$unit") not installed"
      continue
    fi

    if systemctl --user is-active --quiet "$(unit_name "$unit")" >/dev/null 2>&1; then
      systemctl --user stop "$(unit_name "$unit")"
      log "stopped $(unit_name "$unit")"
    else
      log "$(unit_name "$unit") already stopped"
    fi
  done
}

start_control_plane_units() {
  local unit

  for unit in "${CONTROL_PLANE_UNITS[@]}"; do
    if ! unit_exists "$unit"; then
      log "$(unit_name "$unit") not installed"
      continue
    fi

    systemctl --user start "$(unit_name "$unit")"
    log "started $(unit_name "$unit")"
  done
}

print_status() {
  local unit

  if [ -f "$SAFE_MODE_FLAG" ]; then
    echo "safe-mode: ACTIVE"
    for unit in "${CONTROL_PLANE_UNITS[@]}"; do
      if unit_exists "$unit"; then
        printf '  %-17s %s\n' "${unit%.service}:" "$(unit_active_state "$unit")"
      fi
    done
    echo "  health-check cron: running (unaffected)"
    echo "  log-rotation cron: running (unaffected)"
  else
    echo "safe-mode: INACTIVE (normal operation)"
  fi
}

case "$ACTION" in
  on|enable|--service-start)
    log "Entering safe mode — stopping worker dispatch and session pool"
    touch "$SAFE_MODE_FLAG"
    stop_control_plane_units
    log "Safe mode active. SSH, Tailscale, health checks, and log rotation remain running."
    log "Workers will NOT be dispatched or relaunched."
    ;;
  off|disable)
    log "Exiting safe mode — restarting worker services"
    rm -f "$SAFE_MODE_FLAG"
    start_control_plane_units
    log "Normal mode restored. Workers will be dispatched."
    ;;
  --service-stop)
    log "safe mode service stopping — clearing safe mode flag"
    rm -f "$SAFE_MODE_FLAG"
    ;;
  --service-post-stop)
    log "safe mode service stopped — restarting control plane units"
    start_control_plane_units
    ;;
  status)
    print_status
    ;;
  *)
    echo "usage: dws-safe-mode.sh {on|off|status|--service-start|--service-stop|--service-post-stop}"
    exit 1
    ;;
esac
