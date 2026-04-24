#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
STATUS_URL="${DWS_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-}"
SSH_HARDENING_CONF="${DWS_SSH_HARDENING_CONF:-/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf}"
SSH_HARDENING_CANDIDATES="${DWS_SSH_HARDENING_CANDIDATES:-/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf:/etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf:/etc/ssh/sshd_config.d/zz-dws-hardening.conf}"
TAILSCALE_TIMEOUT_SECONDS="${DWS_SUMMARY_TAILSCALE_TIMEOUT_SECONDS:-2}"
CRON_EXPECTED=3
MANAGED_SERVICE_TOTAL=3
MANAGED_WORKERS=(
  dws-a
  dws-b
  worker-c
  worker-d
  worker-e
  worker-f
  worker-g
  worker-h
  worker-i
)

OUTPUT_MODE="text"

OVERALL_STATUS="ok"
SERVICES_STATUS="fail"
SERVICES_OK=0
TASK_MONITOR_ACTIVE=false
SESSIONS_INIT_ACTIVE=false
ORCHESTRATOR_OK=false
ORCHESTRATOR_HTTP_CODE=""

WORKERS_STATUS="fail"
WORKERS_READY=0
WORKERS_TOTAL=${#MANAGED_WORKERS[@]}

QUEUE_STATUS="fail"
QUEUE_PATH=""
QUEUE_PENDING=""
QUEUE_IN_PROGRESS=""
QUEUE_COMPLETED=""
QUEUE_TOTAL=""
QUEUE_TEXT=""

TAILNET_STATUS="fail"
TAILNET_CONNECTED=false
TAILNET_PEERS=""
TAILNET_TEXT=""

SSH_STATUS="fail"
SSH_STATE=""
SSH_TEXT=""
SSH_PATH=""

DISK_STATUS="warn"
DISK_PERCENT=""
DISK_TEXT=""

CRON_STATUS="fail"
CRON_ACTIVE=false
CRON_ENTRIES=0
CRON_TEXT=""

usage() {
  cat <<'EOF'
usage: dws-summary.sh [--json] [--help]

Print a one-line operator summary for services, workers, queue, tailnet, SSH,
disk, and cron. Use --json for structured output.
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

supports_color() {
  [ "$OUTPUT_MODE" = "text" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

paint() {
  local code="$1" text="$2"

  if supports_color; then
    printf '\033[%sm%s\033[0m' "$code" "$text"
  else
    printf '%s' "$text"
  fi
}

green() {
  paint '32' "$1"
}

yellow() {
  paint '33' "$1"
}

red() {
  paint '31' "$1"
}

segment() {
  local status="$1" text="$2"

  case "$status" in
    ok) green "$text" ;;
    warn) yellow "$text" ;;
    *) red "$text" ;;
  esac
}

status_severity() {
  case "$1" in
    ok) printf '0\n' ;;
    warn) printf '1\n' ;;
    *) printf '2\n' ;;
  esac
}

bump_overall() {
  local next="$1"

  if [ "$(status_severity "$next")" -gt "$(status_severity "$OVERALL_STATUS")" ]; then
    OVERALL_STATUS="$next"
  fi
}

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

run_quick() {
  local seconds="$1"
  shift

  if have timeout; then
    timeout "${seconds}s" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

resolved_task_queue_path() {
  local candidate

  if [ -n "$TASK_QUEUE_PATH" ]; then
    printf '%s\n' "$TASK_QUEUE_PATH"
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

http_code() {
  local code=""

  have curl || return 1
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$STATUS_URL" 2>/dev/null || true)
  [ -n "$code" ] || return 1
  printf '%s\n' "$code"
}

user_unit_active() {
  local unit="$1" state=""

  have systemctl || return 1
  state=$(systemctl --user is-active "$unit" 2>/dev/null | sed -n '1p' || true)
  [ "$state" = "active" ]
}

system_unit_active() {
  local unit="$1" state=""

  have systemctl || return 1
  state=$(systemctl is-active "$unit" 2>/dev/null | sed -n '1p' || true)
  [ "$state" = "active" ]
}

count_ready_workers() {
  local names="" worker count=0

  if ! have tmux; then
    printf '0\n'
    return 0
  fi

  names=$(tmux ls -F '#{session_name}' 2>/dev/null || true)
  for worker in "${MANAGED_WORKERS[@]}"; do
    if printf '%s\n' "$names" | grep -Fx -- "$worker" >/dev/null; then
      count=$((count + 1))
    fi
  done

  printf '%s\n' "$count"
}

queue_counts() {
  local path="$1"

  [ -e "$path" ] || return 2
  [ -s "$path" ] || return 3

  if have jq; then
    jq -r '
      (.tasks // []) as $tasks |
      [
        ($tasks | map(select((.status // "") == "pending")) | length),
        ($tasks | map(select((.status // "") == "in_progress")) | length),
        ($tasks | map(select((.status // "") == "completed")) | length),
        ($tasks | length)
      ] | @tsv
    ' "$path" 2>/dev/null || return 4
    return 0
  fi

  if have python3; then
    python3 - "$path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    raise SystemExit(4)

pending = 0
in_progress = 0
completed = 0
tasks = data.get("tasks") or []
for task in tasks:
    status = str(task.get("status") or "")
    if status == "pending":
        pending += 1
    elif status == "in_progress":
        in_progress += 1
    elif status == "completed":
        completed += 1

print(f"{pending}\t{in_progress}\t{completed}\t{len(tasks)}")
PY
    return $?
  fi

  return 5
}

tailnet_connected() {
  have tailscale && run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale status >/dev/null
}

tailnet_peer_count() {
  local payload="" self_ip=""

  have tailscale || return 1

  if have jq; then
    payload=$(run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale status --json || true)
    if [ -n "$payload" ]; then
      jq -r '[((.Peer // {}) | to_entries[]?.value) | select(.Online == true)] | length' <<<"$payload" 2>/dev/null
      return 0
    fi
  fi

  self_ip=$(run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale ip -4 | sed -n '1p' || true)
  run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale status --peers | awk -v self="$self_ip" '
    $1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && $1 != self && $5 != "-" {
      count++
    }
    END {
      print count + 0
    }
  '
}

resolved_ssh_hardening_conf() {
  local candidate
  local old_ifs

  if [ -r "$SSH_HARDENING_CONF" ]; then
    printf '%s\n' "$SSH_HARDENING_CONF"
    return 0
  fi

  old_ifs=$IFS
  IFS=:
  for candidate in $SSH_HARDENING_CANDIDATES; do
    if [ -r "$candidate" ]; then
      printf '%s\n' "$candidate"
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs

  printf '%s\n' "$SSH_HARDENING_CONF"
}

ssh_hardening_values() {
  local path="$1"

  [ -r "$path" ] || return 1
  awk '
    tolower($1) == "passwordauthentication" { pa = tolower($2) }
    tolower($1) == "pubkeyauthentication" { pka = tolower($2) }
    tolower($1) == "kbdinteractiveauthentication" { kia = tolower($2) }
    tolower($1) == "challengeresponseauthentication" { cra = tolower($2) }
    tolower($1) == "permitrootlogin" { pr = tolower($2) }
    tolower($1) == "x11forwarding" { x11 = tolower($2) }
    tolower($1) == "maxauthtries" { mat = $2 }
    END { printf "%s|%s|%s|%s|%s|%s|%s\n", pa, pka, kia, cra, pr, x11, mat }
  ' "$path" 2>/dev/null
}

ssh_hardening_state() {
  local path="$1" values="" pa="" pka="" kia="" cra="" pr="" x11="" mat=""

  values=$(ssh_hardening_values "$path" || true)
  [ -n "$values" ] || {
    printf 'missing\n'
    return 0
  }

  IFS='|' read -r pa pka kia cra pr x11 mat <<<"$values"
  if [ "$pa" = "no" ] &&
     [ "$pka" = "yes" ] &&
     [ "$pr" = "no" ] &&
     [ "$x11" = "no" ] &&
     [ "$mat" = "3" ] &&
     { [ -z "$kia" ] || [ "$kia" = "no" ]; } &&
     { [ -z "$cra" ] || [ "$cra" = "no" ]; }; then
    printf 'ok\n'
  else
    printf 'drift\n'
  fi
}

disk_percent() {
  df -P / 2>/dev/null | awk '
    NR == 2 {
      gsub("%", "", $5)
      print $5 + 0
    }
  '
}

cron_entries_count() {
  local listing=""

  have crontab || {
    printf '0\n'
    return 0
  }

  listing=$(crontab -l 2>/dev/null || true)
  printf '%s\n' "$listing" | grep -Ec '# dws-(health-check|log-rotate|session-cleanup)$' || true
}

collect_services() {
  SERVICES_OK=0
  if user_unit_active dws-task-monitor.service; then
    TASK_MONITOR_ACTIVE=true
    SERVICES_OK=$((SERVICES_OK + 1))
  else
    TASK_MONITOR_ACTIVE=false
  fi

  if user_unit_active dws-sessions-init.service; then
    SESSIONS_INIT_ACTIVE=true
    SERVICES_OK=$((SERVICES_OK + 1))
  else
    SESSIONS_INIT_ACTIVE=false
  fi

  ORCHESTRATOR_HTTP_CODE=$(http_code || true)
  case "$ORCHESTRATOR_HTTP_CODE" in
    2??)
      ORCHESTRATOR_OK=true
      SERVICES_OK=$((SERVICES_OK + 1))
      ;;
    *)
      ORCHESTRATOR_OK=false
      ;;
  esac

  if [ "$SERVICES_OK" -eq "$MANAGED_SERVICE_TOTAL" ]; then
    SERVICES_STATUS="ok"
  elif [ "$SERVICES_OK" -gt 0 ]; then
    SERVICES_STATUS="warn"
  else
    SERVICES_STATUS="fail"
  fi
  bump_overall "$SERVICES_STATUS"
}

collect_workers() {
  WORKERS_READY=$(count_ready_workers)
  if [ "$WORKERS_READY" -eq "$WORKERS_TOTAL" ]; then
    WORKERS_STATUS="ok"
  elif [ "$WORKERS_READY" -gt 0 ]; then
    WORKERS_STATUS="warn"
  else
    WORKERS_STATUS="fail"
  fi
  bump_overall "$WORKERS_STATUS"
}

collect_queue() {
  local counts=""
  local rc=0

  QUEUE_PATH=$(resolved_task_queue_path)
  if counts=$(queue_counts "$QUEUE_PATH"); then
    IFS=$'\t' read -r QUEUE_PENDING QUEUE_IN_PROGRESS QUEUE_COMPLETED QUEUE_TOTAL <<<"$counts"
    QUEUE_TEXT="${QUEUE_PENDING}-pending"
    if [ "$QUEUE_PENDING" -eq 0 ]; then
      QUEUE_STATUS="ok"
    else
      QUEUE_STATUS="warn"
    fi
  else
    rc=$?
    QUEUE_PENDING=""
    QUEUE_IN_PROGRESS=""
    QUEUE_COMPLETED=""
    QUEUE_TOTAL=""
    case "$rc" in
      2) QUEUE_TEXT="missing" ;;
      3) QUEUE_TEXT="empty" ;;
      4) QUEUE_TEXT="invalid" ;;
      5) QUEUE_TEXT="parser-missing" ;;
      *) QUEUE_TEXT="unavailable" ;;
    esac
    QUEUE_STATUS="fail"
  fi
  bump_overall "$QUEUE_STATUS"
}

collect_tailnet() {
  local peers=""

  if tailnet_connected; then
    TAILNET_CONNECTED=true
    peers=$(tailnet_peer_count || true)
    if is_int "$peers"; then
      TAILNET_PEERS="$peers"
      TAILNET_TEXT="${TAILNET_PEERS}-peers"
      if [ "$TAILNET_PEERS" -gt 0 ]; then
        TAILNET_STATUS="ok"
      else
        TAILNET_STATUS="warn"
      fi
    else
      TAILNET_PEERS=""
      TAILNET_TEXT="connected"
      TAILNET_STATUS="warn"
    fi
  else
    TAILNET_CONNECTED=false
    TAILNET_PEERS=""
    TAILNET_TEXT="down"
    TAILNET_STATUS="fail"
  fi
  bump_overall "$TAILNET_STATUS"
}

collect_ssh() {
  SSH_PATH=$(resolved_ssh_hardening_conf)
  SSH_STATE=$(ssh_hardening_state "$SSH_PATH")

  case "$SSH_STATE" in
    ok)
      SSH_STATUS="ok"
      SSH_TEXT="hardened"
      ;;
    drift)
      SSH_STATUS="warn"
      SSH_TEXT="drift"
      ;;
    *)
      SSH_STATUS="fail"
      SSH_TEXT="missing"
      ;;
  esac
  bump_overall "$SSH_STATUS"
}

collect_disk() {
  DISK_PERCENT=$(disk_percent || true)
  if is_int "$DISK_PERCENT"; then
    DISK_TEXT="${DISK_PERCENT}%"
    if [ "$DISK_PERCENT" -ge 90 ]; then
      DISK_STATUS="fail"
    elif [ "$DISK_PERCENT" -ge 80 ]; then
      DISK_STATUS="warn"
    else
      DISK_STATUS="ok"
    fi
  else
    DISK_PERCENT=""
    DISK_TEXT="unavailable"
    DISK_STATUS="warn"
  fi
  bump_overall "$DISK_STATUS"
}

collect_cron() {
  CRON_ENTRIES=$(cron_entries_count)
  if system_unit_active cron; then
    CRON_ACTIVE=true
    if [ "$CRON_ENTRIES" -ge "$CRON_EXPECTED" ]; then
      CRON_STATUS="ok"
    else
      CRON_STATUS="warn"
    fi
  else
    CRON_ACTIVE=false
    CRON_STATUS="fail"
  fi
  CRON_TEXT="${CRON_ENTRIES}/${CRON_EXPECTED}"
  bump_overall "$CRON_STATUS"
}

collect_summary() {
  OVERALL_STATUS="ok"
  collect_services
  collect_workers
  collect_queue
  collect_tailnet
  collect_ssh
  collect_disk
  collect_cron
}

overall_label() {
  case "$1" in
    ok) printf 'OK' ;;
    warn) printf 'WARN' ;;
    *) printf 'FAIL' ;;
  esac
}

print_text() {
  printf '%s %s %s %s %s %s %s %s\n' \
    "$(segment "$OVERALL_STATUS" "$(overall_label "$OVERALL_STATUS")")" \
    "$(segment "$SERVICES_STATUS" "services:${SERVICES_OK}/${MANAGED_SERVICE_TOTAL}")" \
    "$(segment "$WORKERS_STATUS" "workers:${WORKERS_READY}/${WORKERS_TOTAL}")" \
    "$(segment "$QUEUE_STATUS" "queue:${QUEUE_TEXT}")" \
    "$(segment "$TAILNET_STATUS" "tailnet:${TAILNET_TEXT}")" \
    "$(segment "$SSH_STATUS" "ssh:${SSH_TEXT}")" \
    "$(segment "$DISK_STATUS" "disk:${DISK_TEXT}")" \
    "$(segment "$CRON_STATUS" "cron:${CRON_TEXT}")"
}

print_json() {
  printf '{\n'
  printf '  "overall": %s,\n' "$(json_escape "$OVERALL_STATUS")"
  printf '  "services": {\n'
  printf '    "status": %s,\n' "$(json_escape "$SERVICES_STATUS")"
  printf '    "healthy": %s,\n' "$SERVICES_OK"
  printf '    "total": %s,\n' "$MANAGED_SERVICE_TOTAL"
  printf '    "task_monitor": %s,\n' "$TASK_MONITOR_ACTIVE"
  printf '    "sessions_init": %s,\n' "$SESSIONS_INIT_ACTIVE"
  printf '    "orchestrator": %s,\n' "$ORCHESTRATOR_OK"
  printf '    "orchestrator_http_code": %s\n' "$(json_escape "$ORCHESTRATOR_HTTP_CODE")"
  printf '  },\n'
  printf '  "workers": {\n'
  printf '    "status": %s,\n' "$(json_escape "$WORKERS_STATUS")"
  printf '    "ready": %s,\n' "$WORKERS_READY"
  printf '    "total": %s\n' "$WORKERS_TOTAL"
  printf '  },\n'
  printf '  "queue": {\n'
  printf '    "status": %s,\n' "$(json_escape "$QUEUE_STATUS")"
  printf '    "path": %s,\n' "$(json_escape "$QUEUE_PATH")"
  if is_int "$QUEUE_PENDING"; then
    printf '    "pending": %s,\n' "$QUEUE_PENDING"
    printf '    "in_progress": %s,\n' "$QUEUE_IN_PROGRESS"
    printf '    "completed": %s,\n' "$QUEUE_COMPLETED"
    printf '    "total": %s,\n' "$QUEUE_TOTAL"
  else
    printf '    "pending": null,\n'
    printf '    "in_progress": null,\n'
    printf '    "completed": null,\n'
    printf '    "total": null,\n'
  fi
  printf '    "summary": %s\n' "$(json_escape "$QUEUE_TEXT")"
  printf '  },\n'
  printf '  "tailnet": {\n'
  printf '    "status": %s,\n' "$(json_escape "$TAILNET_STATUS")"
  printf '    "connected": %s,\n' "$TAILNET_CONNECTED"
  if is_int "$TAILNET_PEERS"; then
    printf '    "peers": %s,\n' "$TAILNET_PEERS"
  else
    printf '    "peers": null,\n'
  fi
  printf '    "summary": %s\n' "$(json_escape "$TAILNET_TEXT")"
  printf '  },\n'
  printf '  "ssh": {\n'
  printf '    "status": %s,\n' "$(json_escape "$SSH_STATUS")"
  printf '    "state": %s,\n' "$(json_escape "$SSH_STATE")"
  printf '    "summary": %s,\n' "$(json_escape "$SSH_TEXT")"
  printf '    "path": %s\n' "$(json_escape "$SSH_PATH")"
  printf '  },\n'
  printf '  "disk": {\n'
  printf '    "status": %s,\n' "$(json_escape "$DISK_STATUS")"
  if is_int "$DISK_PERCENT"; then
    printf '    "percent": %s,\n' "$DISK_PERCENT"
  else
    printf '    "percent": null,\n'
  fi
  printf '    "summary": %s\n' "$(json_escape "$DISK_TEXT")"
  printf '  },\n'
  printf '  "cron": {\n'
  printf '    "status": %s,\n' "$(json_escape "$CRON_STATUS")"
  printf '    "active": %s,\n' "$CRON_ACTIVE"
  printf '    "entries": %s,\n' "$CRON_ENTRIES"
  printf '    "expected": %s,\n' "$CRON_EXPECTED"
  printf '    "summary": %s\n' "$(json_escape "$CRON_TEXT")"
  printf '  }\n'
  printf '}\n'
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)
        OUTPUT_MODE="json"
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  collect_summary

  if [ "$OUTPUT_MODE" = "json" ]; then
    print_json
  else
    print_text
  fi
}

main "$@"
