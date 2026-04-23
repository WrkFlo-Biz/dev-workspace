#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

DISK_WARN_PCT="${DWS_DISK_WARN_PCT:-85}"
DISK_FAIL_PCT="${DWS_DISK_FAIL_PCT:-95}"
MEM_WARN_PCT="${DWS_MEM_WARN_PCT:-80}"
MEM_FAIL_PCT="${DWS_MEM_FAIL_PCT:-90}"

BACKUP_ROOT="${DWS_BACKUP_ROOT:-$HOME/backups/dev-workspace}"
BACKUP_WARN_AGE_SECONDS="${DWS_BACKUP_WARN_AGE_SECONDS:-86400}"
BACKUP_FAIL_AGE_SECONDS="${DWS_BACKUP_FAIL_AGE_SECONDS:-172800}"

CLEANUP_STAMP_PATH="${DWS_CLEANUP_STAMP_PATH:-/tmp/dws-cleanup.last-success}"
LOG_ROTATE_CRON_LOG_PATH="${DWS_LOG_ROTATE_CRON_LOG_PATH:-/var/log/dws/log-rotate.log}"
SESSION_CLEANUP_CRON_LOG_PATH="${DWS_SESSION_CLEANUP_CRON_LOG_PATH:-/var/log/dws/session-cleanup.log}"
CLEANUP_WARN_AGE_SECONDS="${DWS_CLEANUP_WARN_AGE_SECONDS:-64800}"
CLEANUP_FAIL_AGE_SECONDS="${DWS_CLEANUP_FAIL_AGE_SECONDS:-129600}"

PLANNER_STATUS_PATH="${DWS_PLANNER_STATUS_PATH:-/tmp/planner-status.md}"
PLANNER_STATE_PATH="${DWS_PLANNER_STATE_PATH:-/tmp/planner-state.json}"
PLANNER_LOG_PATH="${DWS_PLANNER_LOG_PATH:-/tmp/planner-log.txt}"
PLANNER_STALE_SECONDS="${DWS_PLANNER_STALE_SECONDS:-1200}"
PLANNER_LOG_STALE_SECONDS="${DWS_PLANNER_LOG_STALE_SECONDS:-3600}"

MONITOR_STATUS_PATH="${DWS_MONITOR_STATUS_PATH:-/tmp/monitor-status.json}"
MONITOR_LOG_PATH="${DWS_MONITOR_LOG_PATH:-/tmp/monitor-log.txt}"
ORCHESTRATOR_MONITOR_LOG_PATH="${DWS_ORCHESTRATOR_MONITOR_LOG_PATH:-/tmp/orchestrator-monitor.log}"
MONITOR_STALE_SECONDS="${DWS_MONITOR_STALE_SECONDS:-1200}"
MONITOR_LOG_STALE_SECONDS="${DWS_MONITOR_LOG_STALE_SECONDS:-3600}"

CRON_SETUP_SCRIPT="${DWS_CRON_SETUP_SCRIPT:-${REPO_ROOT}/bin/dws-cron-setup.sh}"
STATUS_SCRIPT="${DWS_STATUS_SCRIPT:-${REPO_ROOT}/bin/dws-status.sh}"
BACKUP_SCRIPT="${DWS_BACKUP_SCRIPT:-${REPO_ROOT}/bin/dws-backup.sh}"
CLEANUP_SCRIPT="${DWS_CLEANUP_SCRIPT:-${REPO_ROOT}/bin/dws-cleanup.sh}"

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

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

usage() {
  cat <<'EOF'
usage: dws-doctor.sh [--help]

Checks disk and memory pressure, Tailscale, tmux sessions, managed dev-workspace
cron entries, backup recency, cleanup recency, and planner/monitor artifact
freshness. Exits non-zero when one or more checks fail.
EOF
}

validate_config() {
  local value

  for value in \
    "$DISK_WARN_PCT" "$DISK_FAIL_PCT" \
    "$MEM_WARN_PCT" "$MEM_FAIL_PCT" \
    "$BACKUP_WARN_AGE_SECONDS" "$BACKUP_FAIL_AGE_SECONDS" \
    "$CLEANUP_WARN_AGE_SECONDS" "$CLEANUP_FAIL_AGE_SECONDS" \
    "$PLANNER_STALE_SECONDS" "$PLANNER_LOG_STALE_SECONDS" \
    "$MONITOR_STALE_SECONDS" "$MONITOR_LOG_STALE_SECONDS"
  do
    is_int "$value" || {
      printf 'invalid integer configuration: %s\n' "$value" >&2
      exit 1
    }
  done
}

now_epoch() {
  date '+%s' 2>/dev/null || printf '0'
}

format_epoch_utc() {
  local epoch="$1"

  date -u -d "@${epoch}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null && return 0
  date -u -r "$epoch" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null && return 0
  printf 'epoch %s' "$epoch"
}

age_summary() {
  local delta="${1:-0}"

  if [ "$delta" -lt 0 ]; then
    return 1
  fi

  if [ "$delta" -lt 60 ]; then
    printf '%ss ago' "$delta"
  elif [ "$delta" -lt 3600 ]; then
    printf '%sm ago' $((delta / 60))
  elif [ "$delta" -lt 86400 ]; then
    printf '%sh ago' $((delta / 3600))
  else
    printf '%sd ago' $((delta / 86400))
  fi
}

file_mtime_epoch() {
  local path="$1"

  stat -c '%Y' "$path" 2>/dev/null && return 0
  stat -f '%m' "$path" 2>/dev/null && return 0
  return 1
}

file_age_seconds() {
  local path="$1" epoch now

  epoch=$(file_mtime_epoch "$path") || return 1
  now=$(now_epoch)
  [ "$now" -ge "$epoch" ] || return 1
  printf '%s\n' $((now - epoch))
}

file_age_summary() {
  local path="$1" delta

  delta=$(file_age_seconds "$path") || return 1
  age_summary "$delta"
}

artifact_state() {
  local path="$1" stale_after="${2:-0}"
  local epoch now delta

  if [ ! -e "$path" ]; then
    printf 'missing\n'
    return 0
  fi

  if [ ! -s "$path" ]; then
    printf 'empty\n'
    return 0
  fi

  epoch=$(file_mtime_epoch "$path") || {
    printf 'present\n'
    return 0
  }
  now=$(now_epoch)
  [ "$now" -ge "$epoch" ] || {
    printf 'fresh\n'
    return 0
  }
  delta=$((now - epoch))

  if [ "$stale_after" -gt 0 ] && [ "$delta" -ge "$stale_after" ]; then
    printf 'stale\n'
  else
    printf 'fresh\n'
  fi
}

artifact_brief() {
  local label="$1" path="$2" stale_after="$3"
  local state age

  state=$(artifact_state "$path" "$stale_after")
  age=$(file_age_summary "$path" || true)

  case "$state" in
    fresh)
      if [ -n "$age" ]; then
        printf '%s %s' "$label" "$age"
      else
        printf '%s fresh' "$label"
      fi
      ;;
    stale)
      if [ -n "$age" ]; then
        printf '%s stale %s' "$label" "$age"
      else
        printf '%s stale' "$label"
      fi
      ;;
    empty) printf '%s empty' "$label" ;;
    missing) printf '%s missing' "$label" ;;
    present) printf '%s present' "$label" ;;
    *) printf '%s %s' "$label" "$state" ;;
  esac
}

latest_snapshot() {
  local path

  if [ -L "${BACKUP_ROOT}/latest" ]; then
    path=$(readlink -f -- "${BACKUP_ROOT}/latest" 2>/dev/null || true)
    if [ -n "$path" ] && [ -d "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi

  [ -d "$BACKUP_ROOT" ] || return 1
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name latest | sort | tail -1
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

check_managed_cron_entries() {
  local current expected_block block_start block_end marker_failures=0 entry_failures=0
  local tags="" line count tag first=1

  block_start="# >>> dev-workspace managed cron >>>"
  block_end="# <<< dev-workspace managed cron <<<"

  if ! have crontab; then
    fail "crontab is not installed; run ${CRON_SETUP_SCRIPT} after installing cron"
    return
  fi

  if [ ! -x "$CRON_SETUP_SCRIPT" ]; then
    fail "cron setup helper missing: ${CRON_SETUP_SCRIPT}"
    return
  fi

  current=$(crontab -l 2>/dev/null || true)
  if [ -z "$current" ]; then
    fail "no crontab is installed; run ${CRON_SETUP_SCRIPT}"
    return
  fi

  expected_block=$("$CRON_SETUP_SCRIPT" --show 2>/dev/null || true)
  if [ -z "$expected_block" ]; then
    fail "could not render the expected managed cron block; run ${CRON_SETUP_SCRIPT} --show"
    return
  fi

  count=$(printf '%s\n' "$current" | grep -Fxc "$block_start" || true)
  if [ "$count" -ne 1 ]; then
    marker_failures=1
    fail "managed cron block start marker is missing or duplicated; run ${CRON_SETUP_SCRIPT}"
  fi

  count=$(printf '%s\n' "$current" | grep -Fxc "$block_end" || true)
  if [ "$count" -ne 1 ]; then
    marker_failures=1
    fail "managed cron block end marker is missing or duplicated; run ${CRON_SETUP_SCRIPT}"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$block_start" ] && continue
    [ "$line" = "$block_end" ] && continue

    tag=$(printf '%s\n' "$line" | sed -n 's/.*# \(dws-[[:alnum:]-]*\)$/\1/p')
    [ -n "$tag" ] || tag="managed-entry"
    count=$(printf '%s\n' "$current" | grep -Fxc "$line" || true)

    if [ "$first" -eq 1 ]; then
      tags="$tag"
      first=0
    else
      tags="${tags}, ${tag}"
    fi

    if [ "$count" -eq 1 ]; then
      :
    elif [ "$count" -eq 0 ]; then
      entry_failures=1
      fail "missing managed cron entry: ${tag}; run ${CRON_SETUP_SCRIPT}"
    else
      entry_failures=1
      fail "duplicate managed cron entry: ${tag}; run ${CRON_SETUP_SCRIPT}"
    fi
  done <<<"$expected_block"

  if [ "$marker_failures" -eq 0 ] && [ "$entry_failures" -eq 0 ]; then
    pass "managed cron entries installed: ${tags}"
  fi
}

check_backup_recency() {
  local snapshot age_seconds age_text epoch_text metadata_path

  snapshot=$(latest_snapshot || true)
  if [ -z "$snapshot" ]; then
    fail "no backup snapshot found under ${BACKUP_ROOT}; run ${BACKUP_SCRIPT} backup"
    return
  fi

  metadata_path="${snapshot}/meta/summary.txt"
  if [ -f "$metadata_path" ]; then
    :
  else
    metadata_path="$snapshot"
  fi

  age_seconds=$(file_age_seconds "$metadata_path" || true)
  if ! is_int "$age_seconds"; then
    fail "latest backup timestamp could not be read from ${metadata_path}; run ${BACKUP_SCRIPT} backup"
    return
  fi

  age_text=$(age_summary "$age_seconds")
  epoch_text=$(format_epoch_utc "$(file_mtime_epoch "$metadata_path")")

  if [ "$metadata_path" = "${snapshot}/meta/summary.txt" ]; then
    if [ "$age_seconds" -ge "$BACKUP_FAIL_AGE_SECONDS" ]; then
      fail "last backup is ${age_text} (${epoch_text}) [${snapshot}]; run ${BACKUP_SCRIPT} backup"
    elif [ "$age_seconds" -ge "$BACKUP_WARN_AGE_SECONDS" ]; then
      warn "last backup is ${age_text} (${epoch_text}) [${snapshot}]; run ${BACKUP_SCRIPT} backup soon"
    else
      pass "last backup is ${age_text} (${epoch_text}) [${snapshot}]"
    fi
  else
    warn "latest backup metadata is missing; using snapshot dir timestamp ${age_text} (${epoch_text}) [${snapshot}]. Run ${BACKUP_SCRIPT} backup to refresh metadata"
  fi
}

cleanup_log_succeeded() {
  local path="$1"

  [ -s "$path" ] || return 1
  tail -n 8 "$path" 2>/dev/null | grep -Fq 'Summary (apply)'
}

check_cleanup_recency() {
  local signal_path="" age_seconds age_text epoch_text
  local log_path log_epoch best_epoch=0

  if [ -s "$CLEANUP_STAMP_PATH" ]; then
    signal_path="$CLEANUP_STAMP_PATH"
  else
    for log_path in "$LOG_ROTATE_CRON_LOG_PATH" "$SESSION_CLEANUP_CRON_LOG_PATH"; do
      cleanup_log_succeeded "$log_path" || continue
      log_epoch=$(file_mtime_epoch "$log_path" || true)
      is_int "$log_epoch" || continue
      if [ "$log_epoch" -gt "$best_epoch" ]; then
        best_epoch="$log_epoch"
        signal_path="$log_path"
      fi
    done
  fi

  if [ -z "$signal_path" ]; then
    fail "no successful cleanup run found; run ${CLEANUP_SCRIPT} or inspect ${LOG_ROTATE_CRON_LOG_PATH} and ${SESSION_CLEANUP_CRON_LOG_PATH}"
    return
  fi

  age_seconds=$(file_age_seconds "$signal_path" || true)
  if ! is_int "$age_seconds"; then
    fail "cleanup timestamp could not be read from ${signal_path}; run ${CLEANUP_SCRIPT}"
    return
  fi

  age_text=$(age_summary "$age_seconds")
  epoch_text=$(format_epoch_utc "$(file_mtime_epoch "$signal_path")")

  if [ "$signal_path" = "$CLEANUP_STAMP_PATH" ]; then
    if [ "$age_seconds" -ge "$CLEANUP_FAIL_AGE_SECONDS" ]; then
      fail "last cleanup is ${age_text} (${epoch_text}) [${signal_path}]; run ${CLEANUP_SCRIPT} and inspect the cron logs"
    elif [ "$age_seconds" -ge "$CLEANUP_WARN_AGE_SECONDS" ]; then
      warn "last cleanup is ${age_text} (${epoch_text}) [${signal_path}]; run ${CLEANUP_SCRIPT} soon if the next cron cycle does not refresh it"
    else
      pass "last cleanup is ${age_text} (${epoch_text}) [${signal_path}]"
    fi
  else
    warn "cleanup success stamp is missing; falling back to cron log activity ${age_text} (${epoch_text}) [${signal_path}]. The next successful cleanup should create ${CLEANUP_STAMP_PATH}"
  fi
}

planner_family_state() {
  local a b c

  a=$(artifact_state "$PLANNER_STATUS_PATH" "$PLANNER_STALE_SECONDS")
  b=$(artifact_state "$PLANNER_STATE_PATH" "$PLANNER_STALE_SECONDS")
  c=$(artifact_state "$PLANNER_LOG_PATH" "$PLANNER_LOG_STALE_SECONDS")

  if [ "$a" = "fresh" ] || [ "$b" = "fresh" ] || [ "$c" = "fresh" ]; then
    printf 'fresh\n'
  elif [ "$a" != "missing" ] || [ "$b" != "missing" ] || [ "$c" != "missing" ]; then
    printf 'stale\n'
  else
    printf 'missing\n'
  fi
}

planner_family_detail() {
  printf '%s, %s, %s' \
    "$(artifact_brief "status" "$PLANNER_STATUS_PATH" "$PLANNER_STALE_SECONDS")" \
    "$(artifact_brief "state" "$PLANNER_STATE_PATH" "$PLANNER_STALE_SECONDS")" \
    "$(artifact_brief "log" "$PLANNER_LOG_PATH" "$PLANNER_LOG_STALE_SECONDS")"
}

monitor_family_state() {
  local a b c

  a=$(artifact_state "$MONITOR_STATUS_PATH" "$MONITOR_STALE_SECONDS")
  b=$(artifact_state "$MONITOR_LOG_PATH" "$MONITOR_LOG_STALE_SECONDS")
  c=$(artifact_state "$ORCHESTRATOR_MONITOR_LOG_PATH" "$MONITOR_LOG_STALE_SECONDS")

  if [ "$a" = "fresh" ] || [ "$b" = "fresh" ] || [ "$c" = "fresh" ]; then
    printf 'fresh\n'
  elif [ "$a" != "missing" ] || [ "$b" != "missing" ] || [ "$c" != "missing" ]; then
    printf 'stale\n'
  else
    printf 'missing\n'
  fi
}

monitor_family_detail() {
  printf '%s, %s, %s' \
    "$(artifact_brief "status" "$MONITOR_STATUS_PATH" "$MONITOR_STALE_SECONDS")" \
    "$(artifact_brief "log" "$MONITOR_LOG_PATH" "$MONITOR_LOG_STALE_SECONDS")" \
    "$(artifact_brief "orch-log" "$ORCHESTRATOR_MONITOR_LOG_PATH" "$MONITOR_LOG_STALE_SECONDS")"
}

check_runtime_artifacts() {
  local planner_state monitor_state planner_detail monitor_detail
  local planner_hint monitor_hint

  planner_state=$(planner_family_state)
  monitor_state=$(monitor_family_state)
  planner_detail=$(planner_family_detail)
  monitor_detail=$(monitor_family_detail)
  planner_hint="run ${STATUS_SCRIPT}, tail -n 40 ${PLANNER_LOG_PATH}, and restart the planner tmux session if needed"
  monitor_hint="run ${STATUS_SCRIPT}, tail -n 40 ${MONITOR_LOG_PATH}, and restart the monitor tmux session if needed"

  case "${planner_state}:${monitor_state}" in
    fresh:fresh)
      pass "planner artifacts fresh (${planner_detail}); monitor artifacts fresh (${monitor_detail})"
      ;;
    fresh:missing)
      pass "planner artifacts fresh (${planner_detail}); monitor artifacts not present"
      ;;
    missing:fresh)
      pass "monitor artifacts fresh (${monitor_detail}); planner artifacts not present"
      ;;
    fresh:stale)
      warn "planner artifacts fresh (${planner_detail}); monitor artifacts stale (${monitor_detail}); ${monitor_hint}"
      ;;
    stale:fresh)
      warn "monitor artifacts fresh (${monitor_detail}); planner artifacts stale (${planner_detail}); ${planner_hint}"
      ;;
    stale:missing)
      fail "planner artifacts stale (${planner_detail}); ${planner_hint}"
      ;;
    missing:stale)
      fail "monitor artifacts stale (${monitor_detail}); ${monitor_hint}"
      ;;
    stale:stale)
      fail "planner artifacts stale (${planner_detail}); monitor artifacts stale (${monitor_detail}); ${STATUS_SCRIPT} plus both log tails should tell you which loop to restart"
      ;;
    missing:missing)
      fail "no planner or monitor artifacts were found; start the planner or monitor and confirm /tmp status/log files are updating"
      ;;
  esac
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

validate_config

printf 'Dev Workspace Doctor\n'
printf '  host: %s\n' "$(hostname -s 2>/dev/null || hostname)"
printf '  time: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

check_disk
check_memory
check_tailscale
check_tmux_sessions
check_managed_cron_entries
check_backup_recency
check_cleanup_recency
check_runtime_artifacts

printf '\nSummary: %d pass, %d warn, %d fail\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
