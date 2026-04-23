#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${DWS_BOOT_VERIFY_SSH_HOST:-127.0.0.1}"
SSH_PORT="${DWS_BOOT_VERIFY_SSH_PORT:-22}"
SSH_TIMEOUT_SECONDS="${DWS_BOOT_VERIFY_SSH_TIMEOUT_SECONDS:-5}"
LOG_DIR="${DWS_BOOT_VERIFY_LOG_DIR:-/var/log/dws}"
TASK_MONITOR_UNIT="${DWS_BOOT_VERIFY_TASK_MONITOR_UNIT:-dws-task-monitor.service}"
EXPECTED_TMUX_SESSIONS=(
  dws-a
  dws-b
  worker-c
  worker-d
  worker-e
  worker-f
  worker-g
  worker-h
  worker-i
  orchestrator
)

PASS_COUNT=0
FAIL_COUNT=0

supports_color() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

paint() {
  if supports_color; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  %s %s\n' "$(paint 32 PASS)" "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  %s %s\n' "$(paint 31 FAIL)" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: dws-boot-verify.sh [--help]

Verify post-reboot dev-workspace readiness:
  - Tailscale is connected
  - SSH is accepting local connections
  - tmux has the managed session set
  - cron is active and a crontab is loaded
  - /var/log/dws exists
  - dws-task-monitor.service is active

Exits non-zero when one or more checks fail.
EOF
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

validate_config() {
  is_uint "$SSH_PORT" || die "DWS_BOOT_VERIFY_SSH_PORT must be an integer"
  is_uint "$SSH_TIMEOUT_SECONDS" || die "DWS_BOOT_VERIFY_SSH_TIMEOUT_SECONDS must be an integer"
  if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    die "DWS_BOOT_VERIFY_SSH_PORT must be between 1 and 65535"
  fi
  [ "$SSH_TIMEOUT_SECONDS" -ge 1 ] || die "DWS_BOOT_VERIFY_SSH_TIMEOUT_SECONDS must be at least 1"
}

host_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown'
}

timestamp_utc() {
  date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %Z'
}

join_by() {
  local delimiter="$1"
  shift || true
  local first=1 value

  for value in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
      printf '%s' "$value"
    else
      printf '%s%s' "$delimiter" "$value"
    fi
  done
}

active_system_units() {
  local active=() unit

  have systemctl || return 1
  for unit in "$@"; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      active+=("$unit")
    fi
  done
  [ "${#active[@]}" -gt 0 ] || return 1
  join_by ', ' "${active[@]}"
}

active_cron_unit() {
  if have systemctl; then
    if systemctl is-active --quiet cron.service 2>/dev/null; then
      printf 'cron.service\n'
      return 0
    fi
    if systemctl is-active --quiet cron 2>/dev/null; then
      printf 'cron\n'
      return 0
    fi
  fi

  if have service && service cron status >/dev/null 2>&1; then
    printf 'service cron\n'
    return 0
  fi

  if have pgrep && pgrep -x cron >/dev/null 2>&1; then
    printf 'pgrep cron\n'
    return 0
  fi

  return 1
}

active_task_monitor_unit() {
  local bare_unit="${TASK_MONITOR_UNIT%.service}"

  if have systemctl; then
    if systemctl --user is-active --quiet "$TASK_MONITOR_UNIT" 2>/dev/null; then
      printf 'user %s\n' "$TASK_MONITOR_UNIT"
      return 0
    fi
    if [ "$bare_unit" != "$TASK_MONITOR_UNIT" ] && systemctl --user is-active --quiet "$bare_unit" 2>/dev/null; then
      printf 'user %s\n' "$bare_unit"
      return 0
    fi
    if systemctl is-active --quiet "$TASK_MONITOR_UNIT" 2>/dev/null; then
      printf 'system %s\n' "$TASK_MONITOR_UNIT"
      return 0
    fi
    if [ "$bare_unit" != "$TASK_MONITOR_UNIT" ] && systemctl is-active --quiet "$bare_unit" 2>/dev/null; then
      printf 'system %s\n' "$bare_unit"
      return 0
    fi
  fi

  return 1
}

count_active_crontab_entries() {
  awk '
    NF == 0 { next }
    $1 ~ /^#/ { next }
    { count++ }
    END { print count + 0 }
  '
}

read_ssh_banner_python() {
  python3 - "$SSH_HOST" "$SSH_PORT" "$SSH_TIMEOUT_SECONDS" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
timeout = float(sys.argv[3])

with socket.create_connection((host, port), timeout=timeout) as sock:
    sock.settimeout(timeout)
    banner = sock.recv(256)

if not banner:
    raise SystemExit(1)

print(banner.decode("utf-8", "replace").strip())
PY
}

read_ssh_banner_tcp() {
  timeout "$SSH_TIMEOUT_SECONDS" bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 1
    IFS= read -r line <&3 || exit 1
    printf "%s\n" "$line"
    exec 3<&-
    exec 3>&-
  ' _ "$SSH_HOST" "$SSH_PORT"
}

read_ssh_banner() {
  if have python3; then
    read_ssh_banner_python
    return
  fi

  if have timeout; then
    read_ssh_banner_tcp
    return
  fi

  return 1
}

check_tailscale() {
  local ip unit detail

  if ! have tailscale; then
    fail "tailscale command not found"
    return 0
  fi

  if tailscale status >/dev/null 2>&1; then
    ip=$(tailscale ip -4 2>/dev/null | sed -n '1p')
    unit=$(active_system_units tailscaled.service 2>/dev/null || true)
    if [ -n "$unit" ] && [ -n "$ip" ]; then
      pass "tailscale up (${ip}; ${unit})"
    elif [ -n "$ip" ]; then
      pass "tailscale up (${ip})"
    elif [ -n "$unit" ]; then
      pass "tailscale up (${unit})"
    else
      pass "tailscale up"
    fi
    return 0
  fi

  detail=$(tailscale status 2>&1 | sed -n '1p' || true)
  if [ -n "$detail" ]; then
    fail "tailscale not connected: ${detail}"
  else
    fail "tailscale not connected"
  fi
}

check_ssh() {
  local banner active_units

  if ! have python3 && ! have timeout; then
    fail "ssh check unavailable: install python3 or timeout"
    return 0
  fi

  active_units=$(active_system_units ssh.socket ssh.service sshd.socket sshd.service 2>/dev/null || true)
  banner=$(read_ssh_banner 2>/dev/null || true)

  case "$banner" in
    SSH-*)
      if [ -n "$active_units" ]; then
        pass "ssh accepting connections on ${SSH_HOST}:${SSH_PORT} (${banner}; active ${active_units})"
      else
        pass "ssh accepting connections on ${SSH_HOST}:${SSH_PORT} (${banner})"
      fi
      ;;
    '')
      if [ -n "$active_units" ]; then
        fail "ssh not accepting connections on ${SSH_HOST}:${SSH_PORT}; active units: ${active_units}"
      else
        fail "ssh not accepting connections on ${SSH_HOST}:${SSH_PORT}"
      fi
      ;;
    *)
      fail "ssh responded on ${SSH_HOST}:${SSH_PORT} but banner was unexpected: ${banner}"
      ;;
  esac
}

check_tmux() {
  local rows count names missing=() session

  if ! have tmux; then
    fail "tmux command not found"
    return 0
  fi

  rows=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  if [ -z "$rows" ]; then
    fail "tmux server is not running"
    return 0
  fi

  count=$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')
  names=$(printf '%s\n' "$rows" | awk 'NF { printf("%s%s", sep, $0); sep=", " }')

  for session in "${EXPECTED_TMUX_SESSIONS[@]}"; do
    if ! printf '%s\n' "$rows" | grep -Fx -- "$session" >/dev/null 2>&1; then
      missing+=("$session")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    fail "tmux managed sessions missing ($(join_by ', ' "${missing[@]}"); active: ${names})"
  else
    pass "tmux managed sessions ready (${count} sessions: ${names})"
  fi
}

check_cron() {
  local unit current entry_count

  unit=$(active_cron_unit || true)
  if [ -z "$unit" ]; then
    fail "cron service is not active"
    return 0
  fi

  if ! have crontab; then
    fail "crontab command not found"
    return 0
  fi

  current=$(crontab -l 2>/dev/null || true)
  entry_count=$(printf '%s\n' "$current" | count_active_crontab_entries)

  if [ "$entry_count" -gt 0 ]; then
    pass "cron loaded (${unit}; ${entry_count} active crontab entries)"
  else
    fail "cron is active (${unit}) but no active crontab entries are installed"
  fi
}

check_log_dir() {
  local entries

  if [ ! -d "$LOG_DIR" ]; then
    fail "log directory missing (${LOG_DIR})"
    return 0
  fi

  entries=$(find "$LOG_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ' || true)
  [ -n "$entries" ] || entries=0
  pass "log directory present (${LOG_DIR}; ${entries} entries)"
}

check_task_monitor() {
  local unit

  unit=$(active_task_monitor_unit || true)
  if [ -n "$unit" ]; then
    pass "task-monitor service active (${unit})"
  else
    fail "task-monitor service not active (${TASK_MONITOR_UNIT})"
  fi
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    '')
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  validate_config

  printf 'DWS Boot Verify\n'
  printf 'host: %s\n' "$(host_name)"
  printf 'time: %s\n' "$(timestamp_utc)"
  printf '\nChecklist\n'

  check_tailscale
  check_ssh
  check_tmux
  check_cron
  check_log_dir
  check_task_monitor

  if [ "$FAIL_COUNT" -eq 0 ]; then
    printf '\noverall: PASS (%d passed, %d failed)\n' "$PASS_COUNT" "$FAIL_COUNT"
  else
    printf '\noverall: FAIL (%d passed, %d failed)\n' "$PASS_COUNT" "$FAIL_COUNT"
  fi

  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
