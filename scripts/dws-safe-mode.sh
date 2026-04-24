#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

SAFE_MODE_FLAG="/tmp/dws-safe-mode.active"
SERVICES_TO_STOP=(dws-task-monitor dws-sessions-init)

log() { printf "%s [safe-mode] %s\n" "$(date "+%H:%M:%S")" "$*"; }

case "$ACTION" in
  on|enable)
    log "Entering safe mode — stopping worker dispatch and session pool"
    touch "$SAFE_MODE_FLAG"
    for svc in "${SERVICES_TO_STOP[@]}"; do
      if systemctl --user is-active "$svc" >/dev/null 2>&1; then
        systemctl --user stop "$svc"
        log "stopped $svc"
      else
        log "$svc already stopped"
      fi
    done
    log "Safe mode active. SSH, Tailscale, health checks, and log rotation remain running."
    log "Workers will NOT be dispatched or relaunched."
    ;;
  off|disable)
    log "Exiting safe mode — restarting worker services"
    rm -f "$SAFE_MODE_FLAG"
    for svc in "${SERVICES_TO_STOP[@]}"; do
      systemctl --user start "$svc"
      log "started $svc"
    done
    log "Normal mode restored. Workers will be dispatched."
    ;;
  status)
    if [ -f "$SAFE_MODE_FLAG" ]; then
      echo "safe-mode: ACTIVE"
      echo "  task-monitor: $(systemctl --user is-active dws-task-monitor 2>/dev/null || echo stopped)"
      echo "  sessions-init: $(systemctl --user is-active dws-sessions-init 2>/dev/null || echo stopped)"
      echo "  health-check cron: running (unaffected)"
      echo "  log-rotation cron: running (unaffected)"
    else
      echo "safe-mode: INACTIVE (normal operation)"
    fi
    ;;
  *)
    echo "usage: dws-safe-mode.sh {on|off|status}"
    exit 1
    ;;
esac
