#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

STATE_ROOT="${DWS_REBOOT_DRILL_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-workspace/reboot-drill}"
CURRENT_DRILL_FILE="${STATE_ROOT}/current"
RESULTS_PATH="${DWS_REBOOT_DRILL_RESULTS_PATH:-${REPO_ROOT}/docs/reboot-recovery-results.md}"
BOOT_ID_FILE="${DWS_REBOOT_DRILL_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
MONITOR_LOG_PATH="${DWS_REBOOT_DRILL_MONITOR_LOG_PATH:-/var/log/dws/monitor.log}"
PHONE_HEALTH_URL="${DWS_REBOOT_DRILL_PHONE_HEALTH_URL:-http://127.0.0.1:8081/health}"
ORCHESTRATOR_HEALTH_URL="${DWS_REBOOT_DRILL_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"

# On-demand model: there is no fixed repo-owned tmux boot pool to enforce here.
# The drill still captures active sessions before and after reboot for operator
# visibility and pre/post comparison.
EXPECTED_TMUX_SESSIONS=()

TARGET_USER_UNITS=(
  dws-sessions-init.service
  dws-task-monitor.service
  dws-phone-server.service
  wrkflo-orchestrator-api.service
)

TARGET_SYSTEM_UNITS=(
  tailscaled.service
  ssh.socket
  ssh.service
  sshd.socket
  sshd.service
  cron.service
  cron
)

PASS_COUNT=0
FAIL_COUNT=0
CHECK_NAMES=()
CHECK_RESULTS=()
CHECK_DETAILS=()

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

record_check() {
  local result="$1" name="$2" detail="${3:-}" color="32"

  case "$result" in
    PASS)
      PASS_COUNT=$((PASS_COUNT + 1))
      color="32"
      ;;
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      color="31"
      ;;
    *)
      ;;
  esac

  CHECK_NAMES+=("$name")
  CHECK_RESULTS+=("$result")
  CHECK_DETAILS+=("$detail")

  printf '%s %s' "$(paint "$color" "$result")" "$name"
  if [ -n "$detail" ]; then
    printf ' - %s' "$detail"
  fi
  printf '\n'
}

pass() {
  record_check PASS "$1" "${2:-}"
}

fail() {
  record_check FAIL "$1" "${2:-}"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
usage: $(basename "$0") snapshot|verify|help

snapshot
  Capture pre-reboot state for tmux, services, cron, tailscale, and queue.

verify
  Capture post-reboot state, compare it to the latest snapshot, print PASS/FAIL
  checks, and write the markdown report to:
    ${RESULTS_PATH}

Environment overrides:
  DWS_REBOOT_DRILL_STATE_ROOT
  DWS_REBOOT_DRILL_RESULTS_PATH
  DWS_REBOOT_DRILL_BOOT_ID_FILE
  DWS_REBOOT_DRILL_MONITOR_LOG_PATH
  DWS_REBOOT_DRILL_QUEUE_PATH
  DWS_REBOOT_DRILL_PHONE_HEALTH_URL
  DWS_REBOOT_DRILL_ORCHESTRATOR_HEALTH_URL
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

timestamp_utc() {
  date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %Z'
}

timestamp_id() {
  date -u '+%Y%m%dT%H%M%SZ'
}

host_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown'
}

user_name() {
  whoami 2>/dev/null || printf '%s' "${USER:-unknown}"
}

sanitize_field() {
  printf '%s' "$1" | tr '\t\n' '  ' | sed 's/  */ /g;s/^ //;s/ $//'
}

md_escape() {
  printf '%s' "$1" | sed ':a;N;$!ba;s/\n/<br>/g;s/|/\\|/g'
}

write_env_var() {
  local key="$1" value="${2:-}"
  printf '%s=%q\n' "$key" "$value"
}

first_line() {
  sed -n '1p' "$1" 2>/dev/null || true
}

count_lines() {
  awk 'NF { count++ } END { print count + 0 }' "$1" 2>/dev/null
}

csv_from_file() {
  awk 'NF { printf("%s%s", sep, $0); sep = ", " }' "$1" 2>/dev/null
}

csv_from_stdin() {
  awk 'NF { printf("%s%s", sep, $0); sep = ", " }'
}

stat_epoch() {
  local path="$1"

  stat -c '%Y' "$path" 2>/dev/null && return 0
  stat -f '%m' "$path" 2>/dev/null && return 0
  return 1
}

file_age_seconds() {
  local path="$1" epoch now

  epoch=$(stat_epoch "$path") || return 1
  now=$(date '+%s' 2>/dev/null || printf '0')
  [ "$now" -ge "$epoch" ] || return 1
  printf '%s\n' $((now - epoch))
}

boot_id() {
  if [ -r "$BOOT_ID_FILE" ]; then
    sed -n '1p' "$BOOT_ID_FILE"
  else
    printf 'unknown'
  fi
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

count_active_crontab_entries() {
  awk '
    NF == 0 { next }
    $1 ~ /^#/ { next }
    { count++ }
    END { print count + 0 }
  ' "$1" 2>/dev/null
}

count_managed_crontab_entries() {
  grep -Ec 'dws-(health-check|log-rotate|session-cleanup)' "$1" 2>/dev/null || true
}

resolve_queue_path() {
  local candidate

  if [ -n "${DWS_REBOOT_DRILL_QUEUE_PATH:-}" ]; then
    printf '%s\n' "$DWS_REBOOT_DRILL_QUEUE_PATH"
    return 0
  fi

  for candidate in \
    "${REPO_ROOT}/.state/task-queue.json" \
    "$HOME/projects/dev-workspace/.state/task-queue.json" \
    "/tmp/task-queue.json"
  do
    if [ -e "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "${REPO_ROOT}/.state/task-queue.json"
}

queue_counts_tsv() {
  local path="$1"

  [ -e "$path" ] || return 2
  [ -s "$path" ] || return 3

  if have python3; then
    python3 - "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

tasks = payload.get("tasks") or []
pending = sum(1 for task in tasks if (task.get("status") or "") == "pending")
in_progress = sum(1 for task in tasks if (task.get("status") or "") == "in_progress")
completed = sum(1 for task in tasks if (task.get("status") or "") == "completed")
print(f"{pending}\t{in_progress}\t{completed}\t{len(tasks)}")
PY
    return 0
  fi

  if have jq; then
    jq -r '
      (.tasks // []) as $tasks |
      [
        ($tasks | map(select((.status // "") == "pending")) | length),
        ($tasks | map(select((.status // "") == "in_progress")) | length),
        ($tasks | map(select((.status // "") == "completed")) | length),
        ($tasks | length)
      ] | @tsv
    ' "$path" 2>/dev/null
    return 0
  fi

  return 5
}

queue_in_progress_items() {
  local path="$1"

  [ -e "$path" ] || return 2
  [ -s "$path" ] || return 3

  if have python3; then
    python3 - "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

for task in payload.get("tasks") or []:
    if (task.get("status") or "") != "in_progress":
        continue
    task_id = str(task.get("id") or task.get("task_id") or "")
    assigned = str(task.get("assigned") or task.get("worker") or task.get("session") or "")
    repo = str(task.get("repo") or task.get("project") or "")
    print(f"{task_id}\t{assigned}\t{repo}")
PY
    return 0
  fi

  if have jq; then
    jq -r '
      (.tasks // [])[]? |
      select((.status // "") == "in_progress") |
      [(.id // .task_id // ""), (.assigned // .worker // .session // ""), (.repo // .project // "")] |
      @tsv
    ' "$path" 2>/dev/null
    return 0
  fi

  return 5
}

tailscale_peer_count() {
  local json_path="$1"

  [ -s "$json_path" ] || return 1

  if have python3; then
    python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

peer_obj = payload.get("Peer") or {}
print(len(peer_obj))
PY
    return 0
  fi

  if have jq; then
    jq -r '(.Peer // {}) | length' "$json_path" 2>/dev/null
    return 0
  fi

  return 1
}

tmux_missing_expected_csv() {
  local path="$1"
  local session
  local missing=()

  [ "${#EXPECTED_TMUX_SESSIONS[@]}" -gt 0 ] || return 0

  for session in "${EXPECTED_TMUX_SESSIONS[@]}"; do
    if ! grep -Fx -- "$session" "$path" >/dev/null 2>&1; then
      missing+=("$session")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    join_by ', ' "${missing[@]}"
  fi
}

tmux_extra_csv() {
  local path="$1"
  local session

  [ "${#EXPECTED_TMUX_SESSIONS[@]}" -gt 0 ] || return 0

  awk 'NF { print }' "$path" 2>/dev/null | while IFS= read -r session; do
    case " ${EXPECTED_TMUX_SESSIONS[*]} " in
      *" ${session} "*) ;;
      *) printf '%s\n' "$session" ;;
    esac
  done | csv_from_stdin
}

tsv_field_by_key() {
  local path="$1" key="$2" field="$3"

  awk -F '\t' -v key="$key" -v field="$field" '
    $1 == key {
      print $field
      exit
    }
  ' "$path" 2>/dev/null
}

unit_load_state() {
  tsv_field_by_key "$1" "$2" 2
}

unit_file_state() {
  tsv_field_by_key "$1" "$2" 3
}

unit_active_state() {
  tsv_field_by_key "$1" "$2" 4
}

unit_sub_state() {
  tsv_field_by_key "$1" "$2" 5
}

unit_result_state() {
  tsv_field_by_key "$1" "$2" 6
}

unit_exists() {
  local load_state

  load_state=$(unit_load_state "$1" "$2")
  case "$load_state" in
    ''|not-found|unknown) return 1 ;;
    *) return 0 ;;
  esac
}

unit_active_ok() {
  case "${1:-}" in
    active|"active ("*) return 0 ;;
    *) return 1 ;;
  esac
}

unit_summary() {
  local file="$1" unit="$2"
  local load active sub result

  load=$(unit_load_state "$file" "$unit")
  active=$(unit_active_state "$file" "$unit")
  sub=$(unit_sub_state "$file" "$unit")
  result=$(unit_result_state "$file" "$unit")

  case "$load" in
    ''|unknown) printf 'unknown' ;;
    not-found) printf 'not installed' ;;
    *)
      if [ -n "$sub" ] && [ "$sub" != "$active" ]; then
        printf '%s (%s; result=%s)' "${active:-unknown}" "$sub" "${result:-unknown}"
      else
        printf '%s (result=%s)' "${active:-unknown}" "${result:-unknown}"
      fi
      ;;
  esac
}

first_active_unit() {
  local file="$1"
  shift || true
  local unit active

  for unit in "$@"; do
    active=$(unit_active_state "$file" "$unit")
    if unit_active_ok "$active"; then
      printf '%s\n' "$unit"
      return 0
    fi
  done

  return 1
}

capture_http_code() {
  local url="$1"

  if have curl; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || printf 'ERR'
    return 0
  fi

  if have python3; then
    python3 - "$url" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=5) as response:
        print(response.status)
except Exception:
    print("ERR")
PY
    return 0
  fi

  printf 'UNAVAILABLE'
}

capture_tmux_sessions() {
  local dest="$1"

  : >"$dest"
  if ! have tmux; then
    return 1
  fi

  tmux list-sessions -F '#{session_name}' 2>/dev/null | awk 'NF { print }' | sort -u >"$dest" || true
  return 0
}

capture_running_units() {
  local scope="$1" dest="$2" output="" rc=0

  : >"$dest"
  have systemctl || return 1

  if [ "$scope" = "user" ]; then
    if output=$(systemctl --user list-units --type=service --state=running --no-legend --plain 2>/dev/null); then
      rc=0
    else
      rc=$?
    fi
  else
    if output=$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null); then
      rc=0
    else
      rc=$?
    fi
  fi

  printf '%s\n' "$output" | awk 'NF { print $1 }' | sort -u >"$dest"
  [ "$rc" -eq 0 ]
}

capture_unit_table() {
  local scope="$1" dest="$2"
  shift 2 || true
  local unit output
  local -a values args=()

  : >"$dest"
  have systemctl || return 1

  if [ "$scope" = "user" ]; then
    args+=(--user)
  fi

  for unit in "$@"; do
    output=$(
      systemctl "${args[@]}" show "$unit" \
        --property=LoadState \
        --property=UnitFileState \
        --property=ActiveState \
        --property=SubState \
        --property=Result \
        --property=ExecStart \
        --value 2>/dev/null || true
    )
    mapfile -t values <<<"$output"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$unit" \
      "$(sanitize_field "${values[0]:-unknown}")" \
      "$(sanitize_field "${values[1]:-unknown}")" \
      "$(sanitize_field "${values[2]:-unknown}")" \
      "$(sanitize_field "${values[3]:-unknown}")" \
      "$(sanitize_field "${values[4]:-unknown}")" \
      "$(sanitize_field "${values[5]:-}")" \
      >>"$dest"
  done

  return 0
}

capture_crontab() {
  local dest="$1" output=""

  : >"$dest"
  have crontab || return 1

  if output=$(crontab -l 2>/dev/null); then
    :
  else
    output=""
  fi

  printf '%s\n' "$output" >"$dest"
  return 0
}

capture_tailscale() {
  local phase_dir="$1" status_rc=0 json_rc=0
  local status_file="${phase_dir}/tailscale-status.txt"
  local json_file="${phase_dir}/tailscale-status.json"
  local ip_file="${phase_dir}/tailscale-ip.txt"

  : >"$status_file"
  : >"$json_file"
  : >"$ip_file"

  have tailscale || return 1

  if tailscale status >"$status_file" 2>&1; then
    status_rc=0
  else
    status_rc=$?
  fi
  printf '%s\n' "$status_rc" >"${phase_dir}/tailscale-status.rc"

  if tailscale status --json >"$json_file" 2>/dev/null; then
    json_rc=0
  else
    json_rc=$?
    : >"$json_file"
  fi
  printf '%s\n' "$json_rc" >"${phase_dir}/tailscale-status-json.rc"

  tailscale ip -4 2>/dev/null | sed -n '1p' >"$ip_file" || true
  return 0
}

capture_queue() {
  local phase_dir="$1" queue_path queue_state="missing"
  local queue_copy="${phase_dir}/queue.json"

  queue_path=$(resolve_queue_path)
  printf '%s\n' "$queue_path" >"${phase_dir}/queue.path.txt"
  : >"$queue_copy"

  if [ -e "$queue_path" ]; then
    if cp "$queue_path" "$queue_copy" 2>/dev/null; then
      queue_state="present"
    else
      queue_state="unreadable"
    fi
  fi

  printf '%s\n' "$queue_state" >"${phase_dir}/queue.state.txt"
  return 0
}

capture_monitor_log() {
  local phase_dir="$1" monitor_state="missing"

  printf '%s\n' "$MONITOR_LOG_PATH" >"${phase_dir}/monitor-log.path.txt"
  : >"${phase_dir}/monitor-log.tail.txt"
  : >"${phase_dir}/monitor-log.mtime.txt"

  if [ -e "$MONITOR_LOG_PATH" ]; then
    monitor_state="present"
    if ! tail -n 40 "$MONITOR_LOG_PATH" >"${phase_dir}/monitor-log.tail.txt" 2>/dev/null; then
      monitor_state="unreadable"
      : >"${phase_dir}/monitor-log.tail.txt"
    fi
    if ! stat_epoch "$MONITOR_LOG_PATH" >"${phase_dir}/monitor-log.mtime.txt" 2>/dev/null; then
      : >"${phase_dir}/monitor-log.mtime.txt"
    fi
  fi

  printf '%s\n' "$monitor_state" >"${phase_dir}/monitor-log.state.txt"
  return 0
}

capture_linger() {
  local dest="$1"

  : >"$dest"
  have loginctl || return 1
  loginctl show-user "$(user_name)" -p Linger 2>/dev/null >"$dest" || true
  return 0
}

capture_phase_metadata() {
  local phase_dir="$1"

  printf '%s\n' "$(timestamp_utc)" >"${phase_dir}/captured-at.txt"
  printf '%s\n' "$(boot_id)" >"${phase_dir}/boot-id.txt"
  printf '%s\n' "$(host_name)" >"${phase_dir}/hostname.txt"
  printf '%s\n' "$(user_name)" >"${phase_dir}/user.txt"
  printf '%s\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf 'unknown')" >"${phase_dir}/uptime.txt"
}

summarize_phase() {
  local phase_dir="$1"
  local summary_file="${phase_dir}/summary.env"
  local tmux_count tmux_names tmux_missing tmux_extra
  local user_running_count system_running_count
  local tailscale_status_rc tailscale_ip tailscale_peers tailscale_connected="no"
  local cron_active_count cron_managed_count
  local queue_path queue_state queue_parse_state queue_counts queue_pending="" queue_in_progress="" queue_completed="" queue_total=""
  local queue_workers queue_items_rc
  local monitor_log_state monitor_log_mtime
  local linger

  tmux_count=$(count_lines "${phase_dir}/tmux-sessions.txt")
  tmux_names=$(csv_from_file "${phase_dir}/tmux-sessions.txt")
  tmux_missing=$(tmux_missing_expected_csv "${phase_dir}/tmux-sessions.txt")
  tmux_extra=$(tmux_extra_csv "${phase_dir}/tmux-sessions.txt")
  user_running_count=$(count_lines "${phase_dir}/user-running.txt")
  system_running_count=$(count_lines "${phase_dir}/system-running.txt")

  tailscale_status_rc=$(first_line "${phase_dir}/tailscale-status.rc")
  tailscale_ip=$(first_line "${phase_dir}/tailscale-ip.txt")
  tailscale_peers=$(tailscale_peer_count "${phase_dir}/tailscale-status.json" 2>/dev/null || true)
  if [ "${tailscale_status_rc:-1}" = "0" ] && [ -n "$tailscale_ip" ]; then
    tailscale_connected="yes"
  fi

  cron_active_count=$(count_active_crontab_entries "${phase_dir}/cron.txt")
  cron_managed_count=$(count_managed_crontab_entries "${phase_dir}/cron.txt")

  queue_path=$(first_line "${phase_dir}/queue.path.txt")
  queue_state=$(first_line "${phase_dir}/queue.state.txt")
  queue_parse_state="$queue_state"
  queue_workers=""

  if [ "$queue_state" = "present" ]; then
    if queue_counts=$(queue_counts_tsv "${phase_dir}/queue.json" 2>/dev/null); then
      IFS=$'\t' read -r queue_pending queue_in_progress queue_completed queue_total <<<"$queue_counts"
      queue_parse_state="present"
    else
      case $? in
        2) queue_parse_state="missing" ;;
        3) queue_parse_state="empty" ;;
        5) queue_parse_state="parser-missing" ;;
        *) queue_parse_state="invalid" ;;
      esac
    fi

    if queue_workers=$(queue_in_progress_items "${phase_dir}/queue.json" 2>/dev/null); then
      queue_workers=$(printf '%s\n' "$queue_workers" | awk -F '\t' 'NF && $2 != "" { print $2 }' | sort -u | csv_from_stdin)
    else
      queue_items_rc=$?
      case "$queue_items_rc" in
        2|3) queue_workers="" ;;
        *) queue_workers="" ;;
      esac
    fi
  fi

  monitor_log_state=$(first_line "${phase_dir}/monitor-log.state.txt")
  monitor_log_mtime=$(first_line "${phase_dir}/monitor-log.mtime.txt")
  linger=$(sed -n 's/^Linger=//p' "${phase_dir}/linger.txt" 2>/dev/null | sed -n '1p')

  {
    write_env_var CAPTURED_AT "$(first_line "${phase_dir}/captured-at.txt")"
    write_env_var BOOT_ID "$(first_line "${phase_dir}/boot-id.txt")"
    write_env_var HOSTNAME "$(first_line "${phase_dir}/hostname.txt")"
    write_env_var USER_NAME "$(first_line "${phase_dir}/user.txt")"
    write_env_var UPTIME "$(first_line "${phase_dir}/uptime.txt")"
    write_env_var LINGER "${linger:-unknown}"
    write_env_var TMUX_COUNT "$tmux_count"
    write_env_var TMUX_NAMES_CSV "$tmux_names"
    write_env_var TMUX_MISSING_MANAGED_CSV "$tmux_missing"
    write_env_var TMUX_EXTRA_CSV "$tmux_extra"
    write_env_var USER_RUNNING_COUNT "$user_running_count"
    write_env_var SYSTEM_RUNNING_COUNT "$system_running_count"
    write_env_var TAILSCALE_STATUS_RC "${tailscale_status_rc:-1}"
    write_env_var TAILSCALE_CONNECTED "$tailscale_connected"
    write_env_var TAILSCALE_IP "$tailscale_ip"
    write_env_var TAILSCALE_PEER_COUNT "${tailscale_peers:-}"
    write_env_var CRON_ACTIVE_COUNT "$cron_active_count"
    write_env_var CRON_MANAGED_COUNT "$cron_managed_count"
    write_env_var QUEUE_PATH "$queue_path"
    write_env_var QUEUE_STATE "$queue_state"
    write_env_var QUEUE_PARSE_STATE "$queue_parse_state"
    write_env_var QUEUE_PENDING "${queue_pending:-}"
    write_env_var QUEUE_IN_PROGRESS "${queue_in_progress:-}"
    write_env_var QUEUE_COMPLETED "${queue_completed:-}"
    write_env_var QUEUE_TOTAL "${queue_total:-}"
    write_env_var QUEUE_IN_PROGRESS_WORKERS_CSV "$queue_workers"
    write_env_var MONITOR_LOG_STATE "$monitor_log_state"
    write_env_var MONITOR_LOG_MTIME "$monitor_log_mtime"
  } >"$summary_file"
}

load_summary() {
  local file="$1" array_name="$2" key raw value

  [ -f "$file" ] || return 1
  while IFS='=' read -r key raw; do
    [ -n "$key" ] || continue
    value=""
    eval "value=${raw}"
    eval "${array_name}[\$key]=\$value"
  done <"$file"
}

capture_phase() {
  local phase_dir="$1"

  mkdir -p "$phase_dir"
  capture_phase_metadata "$phase_dir"
  capture_tmux_sessions "${phase_dir}/tmux-sessions.txt"
  capture_running_units system "${phase_dir}/system-running.txt"
  capture_running_units user "${phase_dir}/user-running.txt"
  capture_unit_table system "${phase_dir}/system-services.tsv" "${TARGET_SYSTEM_UNITS[@]}"
  capture_unit_table user "${phase_dir}/user-services.tsv" "${TARGET_USER_UNITS[@]}"
  capture_crontab "${phase_dir}/cron.txt"
  capture_tailscale "$phase_dir"
  capture_queue "$phase_dir"
  capture_monitor_log "$phase_dir"
  capture_linger "${phase_dir}/linger.txt"
  summarize_phase "$phase_dir"
}

write_drill_env() {
  local drill_dir="$1" drill_id="$2"

  {
    write_env_var DRILL_ID "$drill_id"
    write_env_var RESULTS_PATH "$RESULTS_PATH"
    write_env_var CREATED_AT "$(timestamp_utc)"
    write_env_var HOSTNAME "$(host_name)"
  } >"${drill_dir}/drill.env"
}

snapshot_mode() {
  local drill_id drill_dir
  declare -A SNAPSHOT=()

  mkdir -p "$STATE_ROOT"
  drill_id=$(timestamp_id)
  drill_dir="${STATE_ROOT}/${drill_id}"
  mkdir -p "$drill_dir"

  write_drill_env "$drill_dir" "$drill_id"
  capture_phase "${drill_dir}/pre"
  printf '%s\n' "$drill_dir" >"$CURRENT_DRILL_FILE"
  load_summary "${drill_dir}/pre/summary.env" SNAPSHOT

  pass "snapshot.state_dir" "captured pre-reboot state in ${drill_dir}"
  pass "snapshot.tmux" "captured ${SNAPSHOT[TMUX_COUNT]:-0} sessions${SNAPSHOT[TMUX_NAMES_CSV]:+ (${SNAPSHOT[TMUX_NAMES_CSV]})}"
  pass "snapshot.services" "captured ${SNAPSHOT[SYSTEM_RUNNING_COUNT]:-0} system and ${SNAPSHOT[USER_RUNNING_COUNT]:-0} user running services"
  pass "snapshot.cron" "captured ${SNAPSHOT[CRON_ACTIVE_COUNT]:-0} active cron entries (${SNAPSHOT[CRON_MANAGED_COUNT]:-0} managed dev-workspace entries)"
  pass "snapshot.tailscale" "captured tailscale rc=${SNAPSHOT[TAILSCALE_STATUS_RC]:-1}${SNAPSHOT[TAILSCALE_IP]:+ ip=${SNAPSHOT[TAILSCALE_IP]}}"
  pass "snapshot.queue" "captured queue state=${SNAPSHOT[QUEUE_PARSE_STATE]:-unknown} path=${SNAPSHOT[QUEUE_PATH]:-unknown}${SNAPSHOT[QUEUE_TOTAL]:+ total=${SNAPSHOT[QUEUE_TOTAL]}}"

  printf '\noverall: %s (%d passed, %d failed)\n' \
    "$( [ "$FAIL_COUNT" -eq 0 ] && printf PASS || printf FAIL )" \
    "$PASS_COUNT" "$FAIL_COUNT"

  [ "$FAIL_COUNT" -eq 0 ]
}

compare_list_missing_csv() {
  local before="$1" after="$2"
  comm -23 "$before" "$after" 2>/dev/null | csv_from_stdin
}

compare_list_added_csv() {
  local before="$1" after="$2"
  comm -13 "$before" "$after" 2>/dev/null | csv_from_stdin
}

verify_optional_service() {
  local label="$1" unit="$2" health_url="$3" pre_user_table="$4" post_user_table="$5"
  local http_code post_state

  if ! unit_exists "$pre_user_table" "$unit"; then
    pass "$label" "not installed before reboot; not expected after reboot"
    printf 'n/a'
    return 0
  fi

  post_state=$(unit_active_state "$post_user_table" "$unit")
  http_code=$(capture_http_code "$health_url")
  printf '%s\n' "$http_code" >"${STATE_ROOT}/.last-${unit}.http"

  if unit_active_ok "$post_state" && [ "$http_code" = "200" ]; then
    pass "$label" "state=$(unit_summary "$post_user_table" "$unit"), health=${http_code}"
  else
    fail "$label" "state=$(unit_summary "$post_user_table" "$unit"), health=${http_code}"
  fi
}

write_report() {
  local drill_dir="$1"
  local tmp_report
  declare -A DRILL=()
  declare -A PRE=()
  declare -A POST=()
  local pre_user_table="${drill_dir}/pre/user-services.tsv"
  local post_user_table="${drill_dir}/post/user-services.tsv"
  local pre_system_table="${drill_dir}/pre/system-services.tsv"
  local post_system_table="${drill_dir}/post/system-services.tsv"
  local pre_tmux="${drill_dir}/pre/tmux-sessions.txt"
  local post_tmux="${drill_dir}/post/tmux-sessions.txt"
  local pre_user_running="${drill_dir}/pre/user-running.txt"
  local post_user_running="${drill_dir}/post/user-running.txt"
  local pre_system_running="${drill_dir}/pre/system-running.txt"
  local post_system_running="${drill_dir}/post/system-running.txt"
  local tmux_missing_after tmux_added_after user_missing_after user_added_after system_missing_after system_added_after
  local optional_phone_http optional_orch_http
  local overall
  local i

  load_summary "${drill_dir}/drill.env" DRILL
  load_summary "${drill_dir}/pre/summary.env" PRE
  load_summary "${drill_dir}/post/summary.env" POST

  tmux_missing_after=$(compare_list_missing_csv "$pre_tmux" "$post_tmux")
  tmux_added_after=$(compare_list_added_csv "$pre_tmux" "$post_tmux")
  user_missing_after=$(compare_list_missing_csv "$pre_user_running" "$post_user_running")
  user_added_after=$(compare_list_added_csv "$pre_user_running" "$post_user_running")
  system_missing_after=$(compare_list_missing_csv "$pre_system_running" "$post_system_running")
  system_added_after=$(compare_list_added_csv "$pre_system_running" "$post_system_running")
  optional_phone_http=$(first_line "${STATE_ROOT}/.last-dws-phone-server.service.http")
  optional_orch_http=$(first_line "${STATE_ROOT}/.last-wrkflo-orchestrator-api.service.http")
  overall=$( [ "$FAIL_COUNT" -eq 0 ] && printf PASS || printf FAIL )

  tmp_report=$(mktemp "${TMPDIR:-/tmp}/dws-reboot-drill-report.XXXXXX")
  # shellcheck disable=SC2016
  {
    printf '# Reboot Recovery Results\n\n'
    printf 'Generated by `%s verify` on %s.\n\n' "$(basename "$0")" "$(timestamp_utc)"
    printf '**Overall:** `%s` (%d passed, %d failed)\n\n' "$overall" "$PASS_COUNT" "$FAIL_COUNT"

    printf '## Metadata\n\n'
    printf '| Field | Value |\n'
    printf '|---|---|\n'
    printf '| Drill ID | `%s` |\n' "$(md_escape "${DRILL[DRILL_ID]:-unknown}")"
    printf '| Snapshot captured | `%s` |\n' "$(md_escape "${PRE[CAPTURED_AT]:-unknown}")"
    printf '| Verification captured | `%s` |\n' "$(md_escape "${POST[CAPTURED_AT]:-unknown}")"
    printf '| Host | `%s` |\n' "$(md_escape "${POST[HOSTNAME]:-unknown}")"
    printf '| Snapshot boot ID | `%s` |\n' "$(md_escape "${PRE[BOOT_ID]:-unknown}")"
    printf '| Current boot ID | `%s` |\n' "$(md_escape "${POST[BOOT_ID]:-unknown}")"
    printf '| State directory | `%s` |\n' "$(md_escape "$drill_dir")"
    printf '| Results file | `%s` |\n' "$(md_escape "$RESULTS_PATH")"

    printf '\n## Checklist\n\n'
    printf '| Check | Result | Details |\n'
    printf '|---|---|---|\n'
    for i in "${!CHECK_NAMES[@]}"; do
      printf '| `%s` | `%s` | %s |\n' \
        "$(md_escape "${CHECK_NAMES[$i]}")" \
        "$(md_escape "${CHECK_RESULTS[$i]}")" \
        "$(md_escape "${CHECK_DETAILS[$i]}")"
    done

    printf '\n## Services\n\n'
    printf '| Unit | Before | After |\n'
    printf '|---|---|---|\n'
    printf '| `tailscaled.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_system_table" "tailscaled.service")")" \
      "$(md_escape "$(unit_summary "$post_system_table" "tailscaled.service")")"
    printf '| `ssh.socket` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_system_table" "ssh.socket")")" \
      "$(md_escape "$(unit_summary "$post_system_table" "ssh.socket")")"
    printf '| `ssh.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_system_table" "ssh.service")")" \
      "$(md_escape "$(unit_summary "$post_system_table" "ssh.service")")"
    printf '| `cron.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_system_table" "cron.service")")" \
      "$(md_escape "$(unit_summary "$post_system_table" "cron.service")")"
    printf '| `cron` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_system_table" "cron")")" \
      "$(md_escape "$(unit_summary "$post_system_table" "cron")")"
    printf '| `dws-sessions-init.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_user_table" "dws-sessions-init.service")")" \
      "$(md_escape "$(unit_summary "$post_user_table" "dws-sessions-init.service")")"
    printf '| `dws-task-monitor.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_user_table" "dws-task-monitor.service")")" \
      "$(md_escape "$(unit_summary "$post_user_table" "dws-task-monitor.service")")"
    printf '| `dws-phone-server.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_user_table" "dws-phone-server.service")")" \
      "$(md_escape "$(unit_summary "$post_user_table" "dws-phone-server.service")")"
    printf '| `wrkflo-orchestrator-api.service` | %s | %s |\n' \
      "$(md_escape "$(unit_summary "$pre_user_table" "wrkflo-orchestrator-api.service")")" \
      "$(md_escape "$(unit_summary "$post_user_table" "wrkflo-orchestrator-api.service")")"

    printf '\nRunning-set diff:\n'
    printf '- User services missing after reboot: %s\n' "$(md_escape "${user_missing_after:-none}")"
    printf '- User services added after reboot: %s\n' "$(md_escape "${user_added_after:-none}")"
    printf '- System services missing after reboot: %s\n' "$(md_escape "${system_missing_after:-none}")"
    printf '- System services added after reboot: %s\n' "$(md_escape "${system_added_after:-none}")"

    printf '\n## tmux\n\n'
    printf '| Metric | Before | After |\n'
    printf '|---|---|---|\n'
    printf '| Session count | `%s` | `%s` |\n' "$(md_escape "${PRE[TMUX_COUNT]:-0}")" "$(md_escape "${POST[TMUX_COUNT]:-0}")"
    printf '| Managed sessions missing | %s | %s |\n' \
      "$(md_escape "${PRE[TMUX_MISSING_MANAGED_CSV]:-none}")" \
      "$(md_escape "${POST[TMUX_MISSING_MANAGED_CSV]:-none}")"
    printf '| Extra sessions | %s | %s |\n' \
      "$(md_escape "${PRE[TMUX_EXTRA_CSV]:-none}")" \
      "$(md_escape "${POST[TMUX_EXTRA_CSV]:-none}")"
    printf '| Full session list | %s | %s |\n' \
      "$(md_escape "${PRE[TMUX_NAMES_CSV]:-none}")" \
      "$(md_escape "${POST[TMUX_NAMES_CSV]:-none}")"
    printf '\n'
    printf '- Sessions missing after reboot: %s\n' "$(md_escape "${tmux_missing_after:-none}")"
    printf '- Sessions added after reboot: %s\n' "$(md_escape "${tmux_added_after:-none}")"

    printf '\n## Cron\n\n'
    printf '| Metric | Before | After |\n'
    printf '|---|---|---|\n'
    printf '| Active crontab entries | `%s` | `%s` |\n' "$(md_escape "${PRE[CRON_ACTIVE_COUNT]:-0}")" "$(md_escape "${POST[CRON_ACTIVE_COUNT]:-0}")"
    printf '| Managed dev-workspace entries | `%s` | `%s` |\n' "$(md_escape "${PRE[CRON_MANAGED_COUNT]:-0}")" "$(md_escape "${POST[CRON_MANAGED_COUNT]:-0}")"

    printf '\n## Tailscale\n\n'
    printf '| Metric | Before | After |\n'
    printf '|---|---|---|\n'
    printf '| Connected | `%s` | `%s` |\n' "$(md_escape "${PRE[TAILSCALE_CONNECTED]:-no}")" "$(md_escape "${POST[TAILSCALE_CONNECTED]:-no}")"
    printf '| Self IP | `%s` | `%s` |\n' "$(md_escape "${PRE[TAILSCALE_IP]:-unknown}")" "$(md_escape "${POST[TAILSCALE_IP]:-unknown}")"
    printf '| Peer count | `%s` | `%s` |\n' "$(md_escape "${PRE[TAILSCALE_PEER_COUNT]:-unknown}")" "$(md_escape "${POST[TAILSCALE_PEER_COUNT]:-unknown}")"

    printf '\n## Queue\n\n'
    printf '| Metric | Before | After |\n'
    printf '|---|---|---|\n'
    printf '| Queue path | `%s` | `%s` |\n' "$(md_escape "${PRE[QUEUE_PATH]:-unknown}")" "$(md_escape "${POST[QUEUE_PATH]:-unknown}")"
    printf '| Queue parse state | `%s` | `%s` |\n' "$(md_escape "${PRE[QUEUE_PARSE_STATE]:-unknown}")" "$(md_escape "${POST[QUEUE_PARSE_STATE]:-unknown}")"
    printf '| Pending | `%s` | `%s` |\n' "$(md_escape "${PRE[QUEUE_PENDING]:-}")" "$(md_escape "${POST[QUEUE_PENDING]:-}")"
    printf '| In progress | `%s` | `%s` |\n' "$(md_escape "${PRE[QUEUE_IN_PROGRESS]:-}")" "$(md_escape "${POST[QUEUE_IN_PROGRESS]:-}")"
    printf '| Completed | `%s` | `%s` |\n' "$(md_escape "${PRE[QUEUE_COMPLETED]:-}")" "$(md_escape "${POST[QUEUE_COMPLETED]:-}")"
    printf '| Total | `%s` | `%s` |\n' "$(md_escape "${PRE[QUEUE_TOTAL]:-}")" "$(md_escape "${POST[QUEUE_TOTAL]:-}")"
    printf '| In-progress workers | %s | %s |\n' \
      "$(md_escape "${PRE[QUEUE_IN_PROGRESS_WORKERS_CSV]:-none}")" \
      "$(md_escape "${POST[QUEUE_IN_PROGRESS_WORKERS_CSV]:-none}")"

    printf '\n## Monitor Log\n\n'
    printf '| Metric | Before | After |\n'
    printf '|---|---|---|\n'
    printf '| Log state | `%s` | `%s` |\n' "$(md_escape "${PRE[MONITOR_LOG_STATE]:-unknown}")" "$(md_escape "${POST[MONITOR_LOG_STATE]:-unknown}")"
    printf '| Log mtime epoch | `%s` | `%s` |\n' "$(md_escape "${PRE[MONITOR_LOG_MTIME]:-}")" "$(md_escape "${POST[MONITOR_LOG_MTIME]:-}")"

    printf '\n## Optional Endpoints\n\n'
    printf '| Endpoint | HTTP code |\n'
    printf '|---|---|\n'
    printf '| `%s` | `%s` |\n' "$(md_escape "$PHONE_HEALTH_URL")" "$(md_escape "${optional_phone_http:-n/a}")"
    printf '| `%s` | `%s` |\n' "$(md_escape "$ORCHESTRATOR_HEALTH_URL")" "$(md_escape "${optional_orch_http:-n/a}")"
  } >"$tmp_report"

  mkdir -p "$(dirname "$RESULTS_PATH")"
  mv "$tmp_report" "$RESULTS_PATH"
}

verify_mode() {
  local drill_dir pre_dir post_dir
  declare -A DRILL=()
  declare -A PRE=()
  declare -A POST=()
  local pre_user_table pre_system_table post_user_table post_system_table
  local ssh_active_unit cron_active_unit sessions_init_state sessions_init_result monitor_state monitor_age
  local phone_http_code orch_http_code
  local queue_item
  local queue_assignment_failures=()
  local assigned_session

  [ -f "$CURRENT_DRILL_FILE" ] || die "no pre-reboot snapshot found; run '$(basename "$0") snapshot' first"
  drill_dir=$(first_line "$CURRENT_DRILL_FILE")
  [ -d "$drill_dir" ] || die "snapshot directory missing: ${drill_dir}"
  [ -f "${drill_dir}/pre/summary.env" ] || die "snapshot summary missing: ${drill_dir}/pre/summary.env"

  pre_dir="${drill_dir}/pre"
  post_dir="${drill_dir}/post"
  mkdir -p "$post_dir"

  capture_phase "$post_dir"
  load_summary "${drill_dir}/drill.env" DRILL
  load_summary "${pre_dir}/summary.env" PRE
  load_summary "${post_dir}/summary.env" POST

  pre_user_table="${pre_dir}/user-services.tsv"
  pre_system_table="${pre_dir}/system-services.tsv"
  post_user_table="${post_dir}/user-services.tsv"
  post_system_table="${post_dir}/system-services.tsv"

  if [ "${PRE[HOSTNAME]:-unknown}" = "${POST[HOSTNAME]:-unknown}" ]; then
    pass "host_matches_snapshot" "${POST[HOSTNAME]:-unknown}"
  else
    fail "host_matches_snapshot" "before=${PRE[HOSTNAME]:-unknown}, after=${POST[HOSTNAME]:-unknown}"
  fi

  if [ "${PRE[BOOT_ID]:-unknown}" != "${POST[BOOT_ID]:-unknown}" ]; then
    pass "reboot_detected" "boot id changed from ${PRE[BOOT_ID]:-unknown} to ${POST[BOOT_ID]:-unknown}"
  else
    fail "reboot_detected" "boot id did not change (${POST[BOOT_ID]:-unknown})"
  fi

  if [ "${POST[LINGER]:-unknown}" = "yes" ] || [ "${POST[LINGER]:-unknown}" = "Yes" ]; then
    pass "linger_enabled" "Linger=${POST[LINGER]}"
  else
    fail "linger_enabled" "Linger=${POST[LINGER]:-unknown}"
  fi

  if unit_active_ok "$(unit_active_state "$post_system_table" "tailscaled.service")"; then
    pass "tailscaled_active" "$(unit_summary "$post_system_table" "tailscaled.service")"
  else
    fail "tailscaled_active" "$(unit_summary "$post_system_table" "tailscaled.service")"
  fi

  if [ "${POST[TAILSCALE_CONNECTED]:-no}" = "yes" ] && [ -n "${POST[TAILSCALE_IP]:-}" ]; then
    pass "tailscale_connected" "ip=${POST[TAILSCALE_IP]} peers=${POST[TAILSCALE_PEER_COUNT]:-unknown}"
  else
    fail "tailscale_connected" "rc=${POST[TAILSCALE_STATUS_RC]:-1} ip=${POST[TAILSCALE_IP]:-missing}"
  fi

  if [ -n "${PRE[TAILSCALE_IP]:-}" ] && [ -n "${POST[TAILSCALE_IP]:-}" ] && [ "${PRE[TAILSCALE_IP]}" = "${POST[TAILSCALE_IP]}" ]; then
    pass "tailscale_ip_matches_snapshot" "${POST[TAILSCALE_IP]}"
  elif [ -n "${PRE[TAILSCALE_IP]:-}" ] && [ -n "${POST[TAILSCALE_IP]:-}" ]; then
    fail "tailscale_ip_matches_snapshot" "before=${PRE[TAILSCALE_IP]}, after=${POST[TAILSCALE_IP]}"
  else
    fail "tailscale_ip_matches_snapshot" "before=${PRE[TAILSCALE_IP]:-missing}, after=${POST[TAILSCALE_IP]:-missing}"
  fi

  ssh_active_unit=$(first_active_unit "$post_system_table" ssh.socket ssh.service sshd.socket sshd.service || true)
  if [ -n "$ssh_active_unit" ]; then
    pass "ssh_transport_active" "$ssh_active_unit is active"
  else
    fail "ssh_transport_active" "no active ssh unit found"
  fi

  cron_active_unit=$(first_active_unit "$post_system_table" cron.service cron || true)
  if [ -n "$cron_active_unit" ]; then
    pass "cron_service_active" "$cron_active_unit is active"
  else
    fail "cron_service_active" "cron service is inactive"
  fi

  if [ "${PRE[CRON_ACTIVE_COUNT]:-0}" = "${POST[CRON_ACTIVE_COUNT]:-0}" ]; then
    pass "cron_entries_match_snapshot" "before=${PRE[CRON_ACTIVE_COUNT]:-0}, after=${POST[CRON_ACTIVE_COUNT]:-0}"
  else
    fail "cron_entries_match_snapshot" "before=${PRE[CRON_ACTIVE_COUNT]:-0}, after=${POST[CRON_ACTIVE_COUNT]:-0}"
  fi

  if [ "${POST[CRON_MANAGED_COUNT]:-0}" -ge 3 ]; then
    pass "cron_managed_entries_present" "managed entries=${POST[CRON_MANAGED_COUNT]:-0}"
  else
    fail "cron_managed_entries_present" "managed entries=${POST[CRON_MANAGED_COUNT]:-0}"
  fi

  sessions_init_state=$(unit_active_state "$post_user_table" "dws-sessions-init.service")
  sessions_init_result=$(unit_result_state "$post_user_table" "dws-sessions-init.service")
  if unit_active_ok "$sessions_init_state" && [ "$sessions_init_result" = "success" ]; then
    pass "dws_sessions_init_active" "$(unit_summary "$post_user_table" "dws-sessions-init.service")"
  else
    fail "dws_sessions_init_active" "$(unit_summary "$post_user_table" "dws-sessions-init.service")"
  fi

  monitor_state=$(unit_active_state "$post_user_table" "dws-task-monitor.service")
  if unit_active_ok "$monitor_state"; then
    pass "dws_task_monitor_active" "$(unit_summary "$post_user_table" "dws-task-monitor.service")"
  else
    fail "dws_task_monitor_active" "$(unit_summary "$post_user_table" "dws-task-monitor.service")"
  fi

  if [ "${POST[MONITOR_LOG_STATE]:-missing}" = "present" ] && monitor_age=$(file_age_seconds "$MONITOR_LOG_PATH" 2>/dev/null); then
    if [ "$monitor_age" -le 180 ]; then
      pass "task_monitor_log_fresh" "monitor log age=${monitor_age}s"
    else
      fail "task_monitor_log_fresh" "monitor log age=${monitor_age}s"
    fi
  else
    fail "task_monitor_log_fresh" "monitor log state=${POST[MONITOR_LOG_STATE]:-missing}"
  fi

  verify_optional_service "dws_phone_server_ready" "dws-phone-server.service" "$PHONE_HEALTH_URL" "$pre_user_table" "$post_user_table"
  verify_optional_service "wrkflo_orchestrator_api_ready" "wrkflo-orchestrator-api.service" "$ORCHESTRATOR_HEALTH_URL" "$pre_user_table" "$post_user_table"

  if [ "${#EXPECTED_TMUX_SESSIONS[@]}" -eq 0 ]; then
    pass "tmux_sessions_captured" "${POST[TMUX_COUNT]:-0} sessions present (on-demand model)"
  elif [ -z "${POST[TMUX_MISSING_MANAGED_CSV]:-}" ]; then
    pass "tmux_managed_sessions_ready" "${POST[TMUX_COUNT]:-0} sessions present"
  else
    fail "tmux_managed_sessions_ready" "missing ${POST[TMUX_MISSING_MANAGED_CSV]}"
  fi

  if [ "${POST[QUEUE_PARSE_STATE]:-missing}" = "present" ]; then
    pass "queue_readable" "path=${POST[QUEUE_PATH]:-unknown} total=${POST[QUEUE_TOTAL]:-0}"
  else
    fail "queue_readable" "path=${POST[QUEUE_PATH]:-unknown} state=${POST[QUEUE_PARSE_STATE]:-missing}"
  fi

  if [ "${PRE[QUEUE_PATH]:-unknown}" = "${POST[QUEUE_PATH]:-unknown}" ]; then
    pass "queue_path_matches_snapshot" "${POST[QUEUE_PATH]:-unknown}"
  else
    fail "queue_path_matches_snapshot" "before=${PRE[QUEUE_PATH]:-unknown}, after=${POST[QUEUE_PATH]:-unknown}"
  fi

  if [ "${POST[QUEUE_PARSE_STATE]:-missing}" = "present" ]; then
    while IFS=$'\t' read -r queue_item assigned_session _; do
      [ -n "${assigned_session:-}" ] || continue
      if ! grep -Fx -- "$assigned_session" "${post_dir}/tmux-sessions.txt" >/dev/null 2>&1; then
        queue_assignment_failures+=("${queue_item:-unknown}->${assigned_session}")
      fi
    done < <(queue_in_progress_items "${post_dir}/queue.json" 2>/dev/null || true)
  fi

  if [ "${#queue_assignment_failures[@]}" -eq 0 ]; then
    pass "queue_in_progress_assignments_valid" "${POST[QUEUE_IN_PROGRESS]:-0} in-progress tasks map to live sessions"
  else
    fail "queue_in_progress_assignments_valid" "$(join_by ', ' "${queue_assignment_failures[@]}")"
  fi

  write_report "$drill_dir"
  pass "results_report_written" "$RESULTS_PATH"

  printf '\noverall: %s (%d passed, %d failed)\n' \
    "$( [ "$FAIL_COUNT" -eq 0 ] && printf PASS || printf FAIL )" \
    "$PASS_COUNT" "$FAIL_COUNT"

  [ "$FAIL_COUNT" -eq 0 ]
}

main() {
  case "${1:-}" in
    snapshot) snapshot_mode ;;
    verify) verify_mode ;;
    help|--help|-h) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
