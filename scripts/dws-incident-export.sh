#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

OUTPUT_DIR="${DWS_INCIDENT_OUTPUT_DIR:-/tmp}"
MONITOR_LOG_PATH="${DWS_INCIDENT_MONITOR_LOG_PATH:-/var/log/dws/monitor.log}"
TASK_QUEUE_PATH="${DWS_INCIDENT_QUEUE_PATH:-${REPO_ROOT}/.state/task-queue.json}"
TAIL_LINES="${DWS_INCIDENT_TAIL_LINES:-200}"
TIMESTAMP="${DWS_INCIDENT_TIMESTAMP:-$(date -u '+%Y%m%dT%H%M%SZ')}"
BUNDLE_BASENAME="dws-incident-${TIMESTAMP}"
ARCHIVE_PATH="${OUTPUT_DIR}/${BUNDLE_BASENAME}.tar.gz"
STAGING_ROOT=''
STAGING_DIR=''

usage() {
  cat <<'EOF'
usage: dws-incident-export.sh [--help]

Collect a compact incident bundle under /tmp by default. The bundle includes:
  - the last 200 lines of monitor.log
  - task-queue.json
  - tmux list-sessions
  - systemctl --user status
  - tailscale status
  - ufw status
  - df -h
  - free -h
  - uptime
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
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

cleanup() {
  if [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
    rm -rf -- "$STAGING_ROOT"
  fi
}

capture_command() {
  local dest="$1"
  shift
  local output status

  if output=$("$@" 2>&1); then
    status=0
  else
    status=$?
  fi

  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    if [ -n "$output" ]; then
      printf '%s\n' "$output"
    fi
    printf '\n[exit=%s]\n' "$status"
  } >"$dest"
}

capture_monitor_log_tail() {
  local dest="$1"

  {
    printf 'source=%s\n' "$MONITOR_LOG_PATH"
    printf 'tail_lines=%s\n\n' "$TAIL_LINES"
    if [ -r "$MONITOR_LOG_PATH" ]; then
      tail -n "$TAIL_LINES" "$MONITOR_LOG_PATH"
    else
      printf 'monitor log not readable: %s\n' "$MONITOR_LOG_PATH"
    fi
  } >"$dest"
}

capture_task_queue() {
  local dest="$1"

  if [ -r "$TASK_QUEUE_PATH" ]; then
    cp -- "$TASK_QUEUE_PATH" "$dest"
    return 0
  fi

  cat >"$dest" <<EOF
{
  "error": "task queue not readable",
  "path": "${TASK_QUEUE_PATH}"
}
EOF
}

write_manifest() {
  local dest="$1"

  cat >"$dest" <<EOF
created_at_utc=$(timestamp_utc)
host=$(host_name)
user=$(current_user)
repo_root=${REPO_ROOT}
monitor_log_path=${MONITOR_LOG_PATH}
task_queue_path=${TASK_QUEUE_PATH}
archive_path=${ARCHIVE_PATH}
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

validate_config() {
  is_uint "$TAIL_LINES" || die "DWS_INCIDENT_TAIL_LINES must be an integer"
  [ "$TAIL_LINES" -ge 1 ] || die 'DWS_INCIDENT_TAIL_LINES must be at least 1'
}

main() {
  parse_args "$@"
  validate_config

  mkdir -p -- "$OUTPUT_DIR"

  STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/${BUNDLE_BASENAME}.XXXXXX")
  STAGING_DIR="${STAGING_ROOT}/${BUNDLE_BASENAME}"
  mkdir -p -- "$STAGING_DIR"
  trap cleanup EXIT

  write_manifest "${STAGING_DIR}/manifest.txt"
  capture_monitor_log_tail "${STAGING_DIR}/monitor-log.tail.txt"
  capture_task_queue "${STAGING_DIR}/task-queue.json"
  capture_command "${STAGING_DIR}/tmux-list-sessions.txt" tmux list-sessions
  capture_command "${STAGING_DIR}/systemctl-user-status.txt" systemctl --user status --no-pager
  capture_command "${STAGING_DIR}/tailscale-status.txt" tailscale status
  capture_command "${STAGING_DIR}/ufw-status.txt" ufw status
  capture_command "${STAGING_DIR}/df.txt" df -h
  capture_command "${STAGING_DIR}/free.txt" free -h
  capture_command "${STAGING_DIR}/uptime.txt" uptime

  tar -C "$STAGING_ROOT" -czf "$ARCHIVE_PATH" "$BUNDLE_BASENAME"

  printf 'incident bundle written: %s\n' "$ARCHIVE_PATH"
}

main "$@"
