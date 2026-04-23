#!/usr/bin/env bash
set -euo pipefail

DISK_WARN_PCT="${DWS_DISK_WARN_PCT:-85}"
DISK_FAIL_PCT="${DWS_DISK_FAIL_PCT:-95}"
MEM_WARN_PCT="${DWS_MEM_WARN_PCT:-80}"
MEM_FAIL_PCT="${DWS_MEM_FAIL_PCT:-90}"
PASS_COUNT=0
WARN_COUNT=0
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
  printf '%s %s\n' "$(paint 32 PASS)" "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '%s %s\n' "$(paint 33 WARN)" "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '%s %s\n' "$(paint 31 FAIL)" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
usage: dws-doctor.sh [--help]

Checks disk usage, memory pressure, Tailscale status, active tmux sessions, and
installed cron jobs. Exits non-zero when one or more checks fail.
EOF
}

check_disk() {
  local used_pct
  used_pct=$(df -Pk / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')

  if [ -z "$used_pct" ]; then
    fail "disk usage could not be determined"
    return
  fi

  if [ "$used_pct" -ge "$DISK_FAIL_PCT" ]; then
    fail "disk usage is ${used_pct}% on /"
  elif [ "$used_pct" -ge "$DISK_WARN_PCT" ]; then
    warn "disk usage is ${used_pct}% on /"
  else
    pass "disk usage is ${used_pct}% on /"
  fi
}

check_memory() {
  local used_pct

  if ! have free; then
    fail "memory usage could not be checked because 'free' is unavailable"
    return
  fi

  used_pct=$(free | awk '/^Mem:/ { printf "%.0f", ($3 / $2) * 100 }')
  if [ -z "$used_pct" ]; then
    fail "memory usage could not be determined"
    return
  fi

  if [ "$used_pct" -ge "$MEM_FAIL_PCT" ]; then
    fail "memory usage is ${used_pct}%"
  elif [ "$used_pct" -ge "$MEM_WARN_PCT" ]; then
    warn "memory usage is ${used_pct}%"
  else
    pass "memory usage is ${used_pct}%"
  fi
}

check_tailscale() {
  local ts_ip

  if ! have tailscale; then
    fail "tailscale is not installed"
    return
  fi

  if ! tailscale status >/dev/null 2>&1; then
    fail "tailscale is installed but not connected"
    return
  fi

  ts_ip=$(tailscale ip -4 2>/dev/null | sed -n '1p')
  if [ -n "$ts_ip" ]; then
    pass "tailscale connected (${ts_ip})"
  else
    pass "tailscale connected"
  fi
}

check_tmux_sessions() {
  local rows session_count attached_count detached_count names

  if ! have tmux; then
    fail "tmux is not installed"
    return
  fi

  rows=$(tmux list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null || true)
  if [ -z "$rows" ]; then
    warn "no tmux sessions are running"
    return
  fi

  session_count=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  attached_count=$(printf '%s\n' "$rows" | awk -F'|' '$2 != "0" { count++ } END { print count + 0 }')
  detached_count=$((session_count - attached_count))
  names=$(printf '%s\n' "$rows" | awk -F'|' '
    BEGIN { first = 1 }
    {
      if (!first) {
        printf ", "
      }
      printf "%s", $1
      first = 0
    }
    END { printf "\n" }')
  pass "tmux sessions running: ${session_count} total (${attached_count} attached, ${detached_count} detached) [${names}]"
}

check_cron_entries() {
  local current active_count managed_count

  if ! have crontab; then
    fail "crontab is not installed"
    return
  fi

  current=$(crontab -l 2>/dev/null || true)
  if [ -z "$current" ]; then
    warn "no cron jobs are installed"
    return
  fi

  active_count=$(printf '%s\n' "$current" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { count++ }
    END { print count + 0 }')
  managed_count=$(printf '%s\n' "$current" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /# dws-/ { count++ }
    END { print count + 0 }')

  if [ "$active_count" -eq 0 ]; then
    warn "crontab exists but contains no active jobs"
  elif [ "$managed_count" -gt 0 ]; then
    pass "cron jobs installed: ${active_count} total (${managed_count} tagged dws jobs)"
  else
    pass "cron jobs installed: ${active_count} total"
  fi
}

case "${1:-}" in
  '' ) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

printf 'Dev Workspace Doctor\n'
printf '  host: %s\n' "$(hostname -s 2>/dev/null || hostname)"
printf '  time: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

check_disk
check_memory
check_tailscale
check_tmux_sessions
check_cron_entries

printf '\nSummary: %d pass, %d warn, %d fail\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
