#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
FLAG_PATH="${DWS_DISPATCH_PAUSE_FLAG:-/tmp/dws-dispatch-paused}"
ACTION="${1:-status}"

usage() {
  cat <<'EOF'
usage: dws-pause-dispatch.sh [on|off|status]

Create or clear the dispatch-pause flag consumed by task-monitor.sh.

Commands:
  on       create /tmp/dws-dispatch-paused and pause new task dispatch
  off      remove the flag and resume new task dispatch
  status   show whether dispatch is currently paused
EOF
}

timestamp_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown\n'
}

host_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown\n'
}

current_user() {
  if [ -n "${USER:-}" ]; then
    printf '%s\n' "$USER"
    return 0
  fi

  id -un 2>/dev/null || printf 'unknown\n'
}

enable_pause() {
  mkdir -p -- "$(dirname -- "$FLAG_PATH")"

  cat >"$FLAG_PATH" <<EOF
created_at_utc=$(timestamp_utc)
user=$(current_user)
host=$(host_name)
repo_root=${REPO_ROOT}
EOF

  printf 'dispatch pause enabled: %s\n' "$FLAG_PATH"
}

disable_pause() {
  if [ -e "$FLAG_PATH" ]; then
    rm -f -- "$FLAG_PATH"
    printf 'dispatch pause cleared: %s\n' "$FLAG_PATH"
  else
    printf 'dispatch pause already cleared: %s\n' "$FLAG_PATH"
  fi
}

show_status() {
  if [ -f "$FLAG_PATH" ]; then
    printf 'dispatch pause: ACTIVE\n'
    printf '  flag: %s\n' "$FLAG_PATH"
  else
    printf 'dispatch pause: INACTIVE\n'
    printf '  flag: %s\n' "$FLAG_PATH"
  fi
}

case "$ACTION" in
  on|enable|pause)
    enable_pause
    ;;
  off|disable|resume)
    disable_pause
    ;;
  status)
    show_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
