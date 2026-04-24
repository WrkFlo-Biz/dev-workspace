#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${DWS_ALERT_LOG_DIR:-/var/log/dws}"
ALERT_LOG_PATH="${DWS_ALERT_LOG_PATH:-${LOG_DIR}/alerts.log}"

MONITOR_RESTART_WINDOW_SECONDS="${DWS_ALERT_MONITOR_RESTART_WINDOW_SECONDS:-600}"
MONITOR_RESTART_LIMIT="${DWS_ALERT_MONITOR_RESTART_LIMIT:-3}"
RATE_LIMIT_WINDOW_SECONDS="${DWS_ALERT_RATE_LIMIT_WINDOW_SECONDS:-900}"
RATE_LIMIT_LIMIT="${DWS_ALERT_RATE_LIMIT_LIMIT:-2}"
DISK_WARN_PCT="${DWS_ALERT_DISK_WARN_PCT:-80}"
DISK_PATH="${DWS_ALERT_DISK_PATH:-/}"
CRON_FAILURE_WINDOW_SECONDS="${DWS_ALERT_CRON_FAILURE_WINDOW_SECONDS:-86400}"
CRON_TAIL_LINES="${DWS_ALERT_CRON_TAIL_LINES:-120}"

ALERT_COUNT=0

usage() {
  cat <<'EOF'
usage: dws-alerting.sh [--help]

Run lightweight alert checks for dev-workspace and append alert lines to
/var/log/dws/alerts.log by default.

Checks:
  - monitor restart loops (>3 start/restart events in 10 minutes)
  - repeated rate limits in the monitor log
  - missing Tailscale peers
  - disk usage above the configured threshold
  - failed cron jobs in recent cron logs

Options:
  -h, --help  show this help

Environment overrides:
  DWS_ALERT_LOG_PATH
  DWS_ALERT_MONITOR_LOG_PATH
  DWS_ALERT_TAILSCALE_REQUIRED_PEERS
  DWS_ALERT_CRON_LOG_PATHS
  DWS_ALERT_NOW_EPOCH
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

validate_config() {
  local value

  for value in \
    "$MONITOR_RESTART_WINDOW_SECONDS" \
    "$MONITOR_RESTART_LIMIT" \
    "$RATE_LIMIT_WINDOW_SECONDS" \
    "$RATE_LIMIT_LIMIT" \
    "$DISK_WARN_PCT" \
    "$CRON_FAILURE_WINDOW_SECONDS" \
    "$CRON_TAIL_LINES"
  do
    is_uint "$value" || die "invalid integer configuration: ${value}"
  done

  [ "$DISK_WARN_PCT" -le 100 ] || die "DWS_ALERT_DISK_WARN_PCT must be 100 or lower"
  [ "$CRON_TAIL_LINES" -ge 1 ] || die "DWS_ALERT_CRON_TAIL_LINES must be at least 1"
}

now_epoch() {
  if [ -n "${DWS_ALERT_NOW_EPOCH:-}" ]; then
    printf '%s\n' "${DWS_ALERT_NOW_EPOCH}"
    return 0
  fi

  date '+%s'
}

format_epoch_ts() {
  local epoch="$1"

  date -u -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
  date -u -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
  return 1
}

alert_timestamp() {
  local epoch

  epoch=$(now_epoch)
  if format_epoch_ts "$epoch" 2>/dev/null; then
    return 0
  fi

  date -u '+%Y-%m-%d %H:%M:%S'
}

window_label() {
  local seconds="$1"

  if [ $((seconds % 3600)) -eq 0 ]; then
    printf '%sh' $((seconds / 3600))
  elif [ $((seconds % 60)) -eq 0 ]; then
    printf '%sm' $((seconds / 60))
  else
    printf '%ss' "$seconds"
  fi
}

shorten() {
  local text="${1:-}"
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

emit_alert() {
  local message="$1" line alert_dir

  alert_dir="${ALERT_LOG_PATH%/*}"
  [ "$alert_dir" != "$ALERT_LOG_PATH" ] || alert_dir='.'
  mkdir -p -- "$alert_dir"

  line="$(alert_timestamp) ALERT ${message}"
  printf '%s\n' "$line" >>"$ALERT_LOG_PATH"
  ALERT_COUNT=$((ALERT_COUNT + 1))
}

resolve_monitor_log_path() {
  local candidate

  for candidate in \
    "${DWS_ALERT_MONITOR_LOG_PATH:-}" \
    "${DWS_MONITOR_LOG:-}" \
    "${LOG_DIR}/monitor.log" \
    "/tmp/monitor-log.txt"
  do
    [ -n "$candidate" ] || continue
    if [ -r "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ -n "${DWS_ALERT_MONITOR_LOG_PATH:-}" ]; then
    printf '%s\n' "${DWS_ALERT_MONITOR_LOG_PATH}"
    return 0
  fi

  printf '%s\n' "${LOG_DIR}/monitor.log"
}

host_from_url() {
  local url="${1:-}" host

  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%\?*}"
  host="${host%%:*}"
  printf '%s\n' "$host"
}

tailscale_required_peers() {
  local mac_target

  if [ -n "${DWS_ALERT_TAILSCALE_REQUIRED_PEERS:-}" ]; then
    printf '%s\n' "${DWS_ALERT_TAILSCALE_REQUIRED_PEERS}"
    return 0
  fi

  if [ -n "${DWS_TAILSCALE_KNOWN_PEERS:-}" ]; then
    printf '%s\n' "${DWS_TAILSCALE_KNOWN_PEERS}"
    return 0
  fi

  mac_target="${DWS_MAC_TAILSCALE_TARGET:-$(host_from_url "${MAC_GUI_URL:-http://100.78.207.22:9223}")}"
  printf 'mac=%s iphone=%s gateway=%s\n' \
    "$mac_target" \
    "${DWS_PHONE_TAILSCALE_TARGET:-100.88.249.22}" \
    "${DWS_GATEWAY_TAILSCALE_TARGET:-100.126.194.98}"
}

recent_log_match_summary() {
  local path="$1" window_seconds="$2" pattern="$3"
  local cutoff_epoch cutoff_ts

  [ -r "$path" ] || {
    printf '0\n\n'
    return 0
  }

  cutoff_epoch=$(( $(now_epoch) - window_seconds ))
  cutoff_ts=$(format_epoch_ts "$cutoff_epoch" 2>/dev/null || true)

  awk -v cutoff="$cutoff_ts" -v pattern="$pattern" '
    function log_ts(text, raw) {
      raw = ""
      if (match(text, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
        raw = substr(text, RSTART, RLENGTH)
        gsub(/T/, " ", raw)
      }
      return raw
    }

    BEGIN {
      count = 0
      last = ""
    }

    {
      ts = log_ts($0)
      if (ts == "") {
        next
      }
      if (cutoff != "" && ts < cutoff) {
        next
      }
      line = tolower($0)
      if (line ~ pattern) {
        count++
        last = $0
      }
    }

    END {
      printf "%d\n%s\n", count, last
    }
  ' "$path"
}

check_monitor_restart_loop() {
  local monitor_log summary restart_count last_line window_text

  monitor_log=$(resolve_monitor_log_path)
  [ -r "$monitor_log" ] || return 0

  summary=$(recent_log_match_summary \
    "$monitor_log" \
    "$MONITOR_RESTART_WINDOW_SECONDS" \
    'monitor (started|online|restarted)|restarting monitor|restart loop|scheduled restart job')
  restart_count=$(printf '%s\n' "$summary" | sed -n '1p')
  last_line=$(printf '%s\n' "$summary" | sed -n '2p')

  is_uint "$restart_count" || restart_count=0
  if [ "$restart_count" -gt "$MONITOR_RESTART_LIMIT" ]; then
    window_text=$(window_label "$MONITOR_RESTART_WINDOW_SECONDS")
    emit_alert "monitor restart loop (${restart_count} start events in ${window_text}; latest: $(shorten "$last_line" 140))"
  fi
}

check_monitor_rate_limits() {
  local monitor_log summary rate_limit_count last_line window_text

  monitor_log=$(resolve_monitor_log_path)
  [ -r "$monitor_log" ] || return 0

  summary=$(recent_log_match_summary \
    "$monitor_log" \
    "$RATE_LIMIT_WINDOW_SECONDS" \
    'rate limit|rate-limit|too many requests|429|retry-after|throttl')
  rate_limit_count=$(printf '%s\n' "$summary" | sed -n '1p')
  last_line=$(printf '%s\n' "$summary" | sed -n '2p')

  is_uint "$rate_limit_count" || rate_limit_count=0
  if [ "$rate_limit_count" -gt "$RATE_LIMIT_LIMIT" ]; then
    window_text=$(window_label "$RATE_LIMIT_WINDOW_SECONDS")
    emit_alert "monitor rate limits repeating (${rate_limit_count} entries in ${window_text}; latest: $(shorten "$last_line" 140))"
  fi
}

tailscale_output_has_target() {
  local status_output="$1" target="$2" target_lower

  target_lower=$(printf '%s\n' "$target" | tr '[:upper:]' '[:lower:]')
  awk -v target="$target_lower" '
    tolower($1) == target || tolower($2) == target { found = 1 }
    END { exit(found ? 0 : 1) }
  ' <<<"$status_output"
}

check_tailscale_peers() {
  local required peers_output entry label target missing=()

  required=$(tailscale_required_peers)
  [ -n "$required" ] || return 0

  if ! have tailscale; then
    emit_alert "tailscale peer check unavailable (tailscale command not found)"
    return 0
  fi

  peers_output=$(tailscale status --peers 2>/dev/null || true)
  if [ -z "$peers_output" ]; then
    emit_alert "tailscale peer check unavailable (tailscale status --peers failed)"
    return 0
  fi

  for entry in $required; do
    case "$entry" in
      *=*)
        label="${entry%%=*}"
        target="${entry#*=}"
        ;;
      *)
        label="$entry"
        target="$entry"
        ;;
    esac

    [ -n "$target" ] || continue
    if ! tailscale_output_has_target "$peers_output" "$target"; then
      if [ "$label" = "$target" ]; then
        missing+=("$target")
      else
        missing+=("${label}(${target})")
      fi
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    emit_alert "tailscale peers missing: $(IFS=', '; printf '%s' "${missing[*]}")"
  fi
}

disk_usage_pct() {
  df -P "$DISK_PATH" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

disk_usage_human() {
  df -hP "$DISK_PATH" 2>/dev/null | awk 'NR == 2 { printf "%s/%s used, %s free", $3, $2, $4 }'
}

check_disk_usage() {
  local used_pct human

  used_pct=$(disk_usage_pct)
  is_uint "$used_pct" || return 0

  if [ "$used_pct" -gt "$DISK_WARN_PCT" ]; then
    human=$(disk_usage_human || true)
    if [ -n "$human" ]; then
      emit_alert "disk usage ${used_pct}% on ${DISK_PATH} (${human})"
    else
      emit_alert "disk usage ${used_pct}% on ${DISK_PATH}"
    fi
  fi
}

file_mtime_epoch() {
  local path="$1"

  stat -c '%Y' "$path" 2>/dev/null && return 0
  stat -f '%m' "$path" 2>/dev/null && return 0
  return 1
}

file_is_recent() {
  local path="$1" window_seconds="$2" epoch now

  epoch=$(file_mtime_epoch "$path") || return 1
  now=$(now_epoch)

  if [ "$now" -lt "$epoch" ]; then
    return 0
  fi

  [ $((now - epoch)) -le "$window_seconds" ]
}

default_cron_log_paths() {
  cat <<EOF
${LOG_DIR}/health-check.log
${LOG_DIR}/log-rotate.log
${LOG_DIR}/session-cleanup.log
/tmp/dws-health-check.cron.log
/tmp/dws-log-rotate.cron.log
/tmp/dws-session-cleanup.cron.log
EOF
}

cron_log_paths() {
  if [ -n "${DWS_ALERT_CRON_LOG_PATHS:-}" ]; then
    printf '%s\n' "${DWS_ALERT_CRON_LOG_PATHS}" | tr ':' '\n'
  else
    default_cron_log_paths
  fi
}

cron_failure_line() {
  local path="$1"

  tail -n "$CRON_TAIL_LINES" -- "$path" 2>/dev/null | awk '
    BEGIN {
      last = ""
    }

    {
      line = tolower($0)
      if (line ~ /(^|[^[:alnum:]])(fail|failed|error|alert)([^[:alnum:]]|$)|traceback|non-zero|exit status/) {
        last = $0
      }
    }

    END {
      print last
    }
  '
}

check_cron_failures() {
  local path failure_line

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -r "$path" ] || continue
    file_is_recent "$path" "$CRON_FAILURE_WINDOW_SECONDS" || continue

    failure_line=$(cron_failure_line "$path")
    if [ -n "$failure_line" ]; then
      emit_alert "cron job failure in $(basename -- "$path"): $(shorten "$failure_line" 160)"
    fi
  done < <(cron_log_paths | awk 'NF && !seen[$0]++')
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown flag: $1"
        ;;
    esac
    shift
  done

  validate_config

  check_monitor_restart_loop
  check_monitor_rate_limits
  check_tailscale_peers
  check_disk_usage
  check_cron_failures

  if [ "$ALERT_COUNT" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
