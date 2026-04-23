#!/usr/bin/env bash
set -euo pipefail

DISK_WARN_PCT="${DWS_HEALTH_DISK_WARN_PCT:-85}"
DISK_FAIL_PCT="${DWS_HEALTH_DISK_FAIL_PCT:-95}"
MEM_WARN_PCT="${DWS_HEALTH_MEM_WARN_PCT:-80}"
MEM_FAIL_PCT="${DWS_HEALTH_MEM_FAIL_PCT:-90}"
LOAD_WARN_PER_CORE="${DWS_HEALTH_LOAD_WARN_PER_CORE:-1.0}"
LOAD_FAIL_PER_CORE="${DWS_HEALTH_LOAD_FAIL_PER_CORE:-2.0}"
REQUIRED_PORTS="${DWS_HEALTH_REQUIRED_PORTS:-22 8080 9222}"

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

bold() {
  paint '1' "$1"
}

cyan() {
  paint '1;36' "$1"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  %s %s\n' "$(paint 32 PASS)" "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '  %s %s\n' "$(paint 33 WARN)" "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  %s %s\n' "$(paint 31 FAIL)" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n%s\n' "$(cyan "$1")"
}

usage() {
  cat <<'EOF'
usage: dws-health-full.sh [--help]

Render a VM health report covering Tailscale, SSH, tmux sessions, disk,
memory, CPU load, toolchain versions, firewall state, and listening ports.
Exits non-zero when one or more checks fail.
EOF
}

float_ge() {
  awk -v left="${1:-0}" -v right="${2:-0}" 'BEGIN { exit((left + 0) >= (right + 0) ? 0 : 1) }'
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

first_line() {
  sed -n '1p'
}

shorten() {
  local text="$1"
  local max_chars="${2:-160}"

  awk -v max="$max_chars" '
    {
      if (length($0) <= max) {
        print $0
      } else {
        print substr($0, 1, max - 3) "..."
      }
    }
  ' <<<"$text"
}

host_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown'
}

timestamp_utc() {
  date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %Z'
}

disk_usage_pct() {
  df -P / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

disk_usage_human() {
  df -hP / 2>/dev/null | awk 'NR == 2 { printf "%s/%s used, %s free", $3, $2, $4 }'
}

memory_usage_pct() {
  free 2>/dev/null | awk '/^Mem:/ { printf "%.0f", ($3 / $2) * 100 }'
}

memory_usage_human() {
  free -h 2>/dev/null | awk '/^Mem:/ { printf "%s/%s used, %s available", $3, $2, $7 }'
}

core_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null && return 0
  nproc 2>/dev/null && return 0
  printf '1\n'
}

load_averages() {
  local loads

  if [ -n "${DWS_HEALTH_LOAD_AVERAGES:-}" ]; then
    printf '%s\n' "${DWS_HEALTH_LOAD_AVERAGES}"
    return 0
  fi

  if [ -r /proc/loadavg ]; then
    awk '{ print $1, $2, $3 }' /proc/loadavg
    return 0
  fi

  loads=$(uptime 2>/dev/null | sed -n 's/.*load average[s]*: //p' | tr -d ',')
  if [ -n "$loads" ]; then
    printf '%s\n' "$loads"
    return 0
  fi

  return 1
}

sshd_state() {
  local unit

  if have systemctl; then
    for unit in ssh sshd; do
      if systemctl is-active --quiet "${unit}.service" 2>/dev/null; then
        printf 'active (%s.service)\n' "$unit"
        return 0
      fi
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        printf 'active (%s)\n' "$unit"
        return 0
      fi
    done
  fi

  if have service; then
    for unit in ssh sshd; do
      if service "$unit" status >/dev/null 2>&1; then
        printf 'active (service %s)\n' "$unit"
        return 0
      fi
    done
  fi

  if have pgrep && pgrep -x sshd >/dev/null 2>&1; then
    printf 'active (pgrep sshd)\n'
    return 0
  fi

  return 1
}

tmux_rows() {
  tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null || true
}

tool_version() {
  local tool="$1"
  shift || true
  local cmd

  for cmd in "$@"; do
    if have "$cmd"; then
      case "$cmd" in
        python3|python) "$cmd" --version 2>&1 | first_line ;;
        node) "$cmd" --version 2>&1 | first_line ;;
        git) "$cmd" --version 2>&1 | first_line ;;
        *) "$cmd" --version 2>&1 | first_line ;;
      esac
      return 0
    fi
  done

  printf '%s missing\n' "$tool"
  return 1
}

firewall_snapshot() {
  local out rules

  if have ufw; then
    out=$(ufw status numbered 2>&1 || true)
    case "$out" in
      *"You need to be root"*)
        out=$(sudo -n ufw status numbered 2>&1 || true)
        ;;
    esac
    if printf '%s\n' "$out" | grep -q '^Status: active'; then
      rules=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\(\[[^]]*\].*\)$/\1/p' | head -n 6)
      [ -n "$rules" ] || rules='no numbered rules'
      printf 'ufw|active|%s\n' "$(printf '%s' "$rules" | paste -sd '; ' -)"
      return 0
    fi
    if printf '%s\n' "$out" | grep -q '^Status: inactive'; then
      printf 'ufw|inactive|no rules loaded\n'
      return 0
    fi
    if printf '%s\n' "$out" | grep -q 'You need to be root'; then
      printf 'ufw|unreadable|ufw rules require elevated privileges\n'
      return 0
    fi
    printf 'ufw|unknown|%s\n' "$(printf '%s\n' "$out" | head -n 3 | paste -sd '; ' -)"
    return 0
  fi

  if have firewall-cmd; then
    out=$(firewall-cmd --state 2>&1 || true)
    if [ "$out" = "running" ]; then
      rules=$(firewall-cmd --list-all 2>/dev/null | sed -n '
        s/^[[:space:]]*services:[[:space:]]*/services: /p
        s/^[[:space:]]*ports:[[:space:]]*/ports: /p
      ' | head -n 4)
      [ -n "$rules" ] || rules='no services or ports reported'
      printf 'firewalld|running|%s\n' "$(printf '%s' "$rules" | paste -sd '; ' -)"
      return 0
    fi
    printf 'firewalld|%s|firewalld is not running\n' "$(printf '%s' "$out" | first_line)"
    return 0
  fi

  if have nft; then
    out=$(nft list ruleset 2>/dev/null || sudo -n nft list ruleset 2>/dev/null || true)
    if [ -n "$out" ]; then
      rules=$(printf '%s\n' "$out" | sed -n '1,6p' | paste -sd '; ' -)
      printf 'nftables|present|%s\n' "${rules:-ruleset loaded}"
    else
      printf 'nftables|unreadable|ruleset could not be read without elevation\n'
    fi
    return 0
  fi

  if have iptables; then
    out=$(iptables -S 2>/dev/null || sudo -n iptables -S 2>/dev/null || true)
    if [ -n "$out" ]; then
      rules=$(printf '%s\n' "$out" | sed -n '1,6p' | paste -sd '; ' -)
      printf 'iptables|present|%s\n' "${rules:-ruleset loaded}"
    else
      printf 'iptables|unreadable|ruleset could not be read without elevation\n'
    fi
    return 0
  fi

  printf 'none|missing|no supported firewall tool found\n'
}

listening_rows() {
  ss -lntpH 2>/dev/null || ss -lntH 2>/dev/null || true
}

port_row() {
  local port="$1"
  local rows="$2"

  awk -v target="$port" '
    function port_of(addr, raw) {
      raw = addr
      if (raw ~ /\]:/) {
        sub(/^.*\]:/, "", raw)
      } else {
        sub(/^.*:/, "", raw)
      }
      return raw
    }

    {
      local_addr = $4
      if (port_of(local_addr) == target) {
        print $0
        exit
      }
    }
  ' <<<"$rows"
}

render_header() {
  printf '%s\n' "$(bold 'VM Health Report')"
  printf '  host: %s\n' "$(host_name)"
  printf '  time: %s\n' "$(timestamp_utc)"
  printf '  ports: %s\n' "${REQUIRED_PORTS}"
}

check_tailscale() {
  local ts_ip

  section "Connectivity"

  if ! have tailscale; then
    fail "tailscale CLI missing"
    return
  fi

  if ! tailscale status >/dev/null 2>&1; then
    fail "tailscale not connected"
    return
  fi

  ts_ip=$(tailscale ip -4 2>/dev/null | sed -n '1p')
  if [ -n "$ts_ip" ]; then
    pass "tailscale connected (${ts_ip})"
  else
    warn "tailscale connected, but no IPv4 address was reported"
  fi
}

check_sshd() {
  local state

  if state=$(sshd_state); then
    pass "ssh daemon ${state}"
  else
    fail "ssh daemon not running"
  fi
}

check_tmux() {
  local rows session_count attached_count detached_count details zero_window_sessions

  section "Sessions"

  if ! have tmux; then
    fail "tmux missing"
    return
  fi

  rows=$(tmux_rows)
  if [ -z "$rows" ]; then
    warn "no tmux sessions running"
    return
  fi

  zero_window_sessions=$(printf '%s\n' "$rows" | awk -F'|' '$2 < 1 { print $1 }')
  if [ -n "$zero_window_sessions" ]; then
    fail "tmux sessions with zero windows: $(printf '%s\n' "$zero_window_sessions" | paste -sd ', ' -)"
    return
  fi

  session_count=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  attached_count=$(printf '%s\n' "$rows" | awk -F'|' '$3 != "0" { count++ } END { print count + 0 }')
  detached_count=$((session_count - attached_count))
  details=$(printf '%s\n' "$rows" | awk -F'|' '
    BEGIN { first = 1 }
    {
      if (!first) {
        printf ", "
      }
      printf "%s (%sw,%s)", $1, $2, ($3 == "0" ? "detached" : "attached")
      first = 0
    }
    END { printf "\n" }
  ')
  pass "tmux sessions alive: ${session_count} total (${attached_count} attached, ${detached_count} detached) [${details}]"
}

check_disk() {
  local used_pct human

  section "Resources"

  if ! have df; then
    fail "disk usage unavailable because df is missing"
    return
  fi

  used_pct=$(disk_usage_pct)
  human=$(disk_usage_human)
  if [ -z "$used_pct" ] || [ -z "$human" ]; then
    fail "disk usage could not be determined"
    return
  fi

  if [ "$used_pct" -ge "$DISK_FAIL_PCT" ]; then
    fail "disk usage ${used_pct}% (${human})"
  elif [ "$used_pct" -ge "$DISK_WARN_PCT" ]; then
    warn "disk usage ${used_pct}% (${human})"
  else
    pass "disk usage ${used_pct}% (${human})"
  fi
}

check_memory() {
  local used_pct human

  if ! have free; then
    fail "memory usage unavailable because free is missing"
    return
  fi

  used_pct=$(memory_usage_pct)
  human=$(memory_usage_human)
  if [ -z "$used_pct" ] || [ -z "$human" ]; then
    fail "memory usage could not be determined"
    return
  fi

  if [ "$used_pct" -ge "$MEM_FAIL_PCT" ]; then
    fail "memory usage ${used_pct}% (${human})"
  elif [ "$used_pct" -ge "$MEM_WARN_PCT" ]; then
    warn "memory usage ${used_pct}% (${human})"
  else
    pass "memory usage ${used_pct}% (${human})"
  fi
}

check_cpu_load() {
  local loads one five fifteen cores warn_threshold fail_threshold

  if ! have awk; then
    fail "cpu load unavailable because awk is missing"
    return
  fi

  loads=$(load_averages || true)
  if [ -z "$loads" ]; then
    fail "cpu load could not be determined"
    return
  fi

  read -r one five fifteen <<<"$loads"
  cores=$(core_count)
  warn_threshold=$(awk -v cores="$cores" -v mult="$LOAD_WARN_PER_CORE" 'BEGIN { printf "%.2f", cores * mult }')
  fail_threshold=$(awk -v cores="$cores" -v mult="$LOAD_FAIL_PER_CORE" 'BEGIN { printf "%.2f", cores * mult }')

  if float_ge "$one" "$fail_threshold"; then
    fail "cpu load ${one} ${five} ${fifteen} on ${cores} cores"
  elif float_ge "$one" "$warn_threshold"; then
    warn "cpu load ${one} ${five} ${fifteen} on ${cores} cores"
  else
    pass "cpu load ${one} ${five} ${fifteen} on ${cores} cores"
  fi
}

check_toolchain() {
  local version

  section "Toolchain"

  if version=$(tool_version python python3 python); then
    pass "python ${version}"
  else
    fail "$version"
  fi

  if version=$(tool_version node node); then
    pass "node ${version}"
  else
    fail "$version"
  fi

  if version=$(tool_version git git); then
    pass "git ${version}"
  else
    fail "$version"
  fi
}

check_firewall() {
  local backend state detail

  section "Security"

  IFS='|' read -r backend state detail <<<"$(firewall_snapshot)"
  detail=$(shorten "$detail" 180)

  case "$backend:$state" in
    ufw:active|firewalld:running|nftables:present|iptables:present)
      pass "firewall ${backend} ${state}"
      ;;
    none:missing)
      warn "firewall unavailable"
      ;;
    *)
      warn "firewall ${backend} ${state}"
      ;;
  esac

  printf '    rules: %s\n' "$detail"
}

check_ports() {
  local rows port row local_addr process field_count

  if ! have ss; then
    fail "open ports could not be checked because ss is missing"
    return
  fi

  rows=$(listening_rows)
  for port in $REQUIRED_PORTS; do
    row=$(port_row "$port" "$rows")
    if [ -n "$row" ]; then
      local_addr=$(awk '{ print $4 }' <<<"$row")
      field_count=$(awk '{ print NF }' <<<"$row")
      if [ "$field_count" -ge 6 ]; then
        process=$(awk '{ print $6 }' <<<"$row")
        pass "port ${port} listening on ${local_addr} (${process})"
      else
        pass "port ${port} listening on ${local_addr}"
      fi
    else
      fail "port ${port} not listening"
    fi
  done
}

render_summary() {
  local overall

  if [ "$FAIL_COUNT" -gt 0 ]; then
    overall=$(paint 31 FAIL)
  elif [ "$WARN_COUNT" -gt 0 ]; then
    overall=$(paint 33 WARN)
  else
    overall=$(paint 32 PASS)
  fi

  printf '\n%s\n' "$(bold 'Summary')"
  printf '  overall: %s\n' "$overall"
  printf '  pass: %s\n' "$PASS_COUNT"
  printf '  warn: %s\n' "$WARN_COUNT"
  printf '  fail: %s\n' "$FAIL_COUNT"
}

case "${1:-}" in
  '') ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

render_header
check_tailscale
check_sshd
check_tmux
check_disk
check_memory
check_cpu_load
check_toolchain
check_firewall
check_ports
render_summary

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
