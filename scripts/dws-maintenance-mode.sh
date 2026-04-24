#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
LOCK_PATH="${DWS_MAINTENANCE_LOCK_PATH:-${REPO_ROOT}/.state/maintenance-lock}"
ACTION='enable'

usage() {
  cat <<'EOF'
usage: dws-maintenance-mode.sh [--resume] [--help]

Create or clear the maintenance lock used to pause queue dispatch.

Options:
  --resume    remove the maintenance lock
  -h, --help  show this help
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

enable_maintenance() {
  mkdir -p -- "$(dirname -- "$LOCK_PATH")"

  cat >"$LOCK_PATH" <<EOF
created_at_utc=$(timestamp_utc)
user=$(current_user)
host=$(host_name)
repo_root=$REPO_ROOT
EOF

  printf 'maintenance mode enabled: %s\n' "$LOCK_PATH"
}

resume_dispatch() {
  if [ -e "$LOCK_PATH" ]; then
    rm -f -- "$LOCK_PATH"
    printf 'maintenance mode cleared: %s\n' "$LOCK_PATH"
  else
    printf 'maintenance mode already cleared: %s\n' "$LOCK_PATH"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --resume)
      ACTION='resume'
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

case "$ACTION" in
  enable)
    enable_maintenance
    ;;
  resume)
    resume_dispatch
    ;;
esac
