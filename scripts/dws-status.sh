#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
STATUS_URL="${DWS_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-/tmp/task-queue.json}"
HEALTH_LOG="${DWS_HEALTH_LOG_PATH:-/tmp/dws-health.log}"
PLANNER_STATUS_PATH="${DWS_PLANNER_STATUS_PATH:-/tmp/planner-status.md}"
PLANNER_STATE_PATH="${DWS_PLANNER_STATE_PATH:-/tmp/planner-state.json}"
PLANNER_LOG_PATH="${DWS_PLANNER_LOG_PATH:-/tmp/planner-log.txt}"
PLANNER_STALE_SECONDS="${DWS_PLANNER_STALE_SECONDS:-1200}"
PLANNER_LOG_STALE_SECONDS="${DWS_PLANNER_LOG_STALE_SECONDS:-3600}"
MONITOR_SERVICE_NAME="${DWS_MONITOR_SERVICE_NAME:-dws-task-monitor}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dws-env.sh"

[ -n "${AZURE_OPENAI_API_KEY:-}" ] || {
  [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"
}

usage() {
  cat <<'EOF'
usage: dws-status.sh [--json|--motd|--help]

Query the local orchestrator workspace health endpoint and render either raw
JSON, a one-line MOTD summary, or a full operator status page.
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

now_epoch() {
  date '+%s' 2>/dev/null || printf '0'
}

age_summary() {
  local delta=${1:-0}

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

  need_cmd stat || return 1
  stat -c '%Y' "$path" 2>/dev/null && return 0
  stat -f '%m' "$path" 2>/dev/null && return 0
  return 1
}

file_age_summary() {
  local path="$1" epoch now delta

  epoch=$(file_mtime_epoch "$path") || return 1
  now=$(now_epoch)
  [ "$now" -ge "$epoch" ] || return 1
  delta=$((now - epoch))
  age_summary "$delta"
}

host_info() {
  local host user

  host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '?')
  user=$(whoami 2>/dev/null || printf '?')
  printf '%s@%s\n' "$user" "$host"
}

active_session_summary() {
  local count="${1:-0}" label

  if [ "$count" -eq 1 ]; then
    label='1 active'
  else
    label="${count} active"
  fi

  if [ "$count" -gt 0 ]; then
    printf '%s' "$(cyan "$label")"
  else
    printf '%s' "$(dim "$label")"
  fi
}

header_tailscale_ip() {
  local body="${1:-}" ip=''

  if [ -n "$body" ]; then
    ip=$(jq -r '.tailscale.ip // ""' <<<"$body" 2>/dev/null || true)
  fi

  if [ -z "$ip" ] && need_cmd tailscale; then
    ip=$(tailscale ip -4 2>/dev/null | sed -n '1p' || true)
  fi

  printf '%s\n' "$ip"
}

tailscale_ip_badge() {
  local ip="${1:-}"

  if [ -n "$ip" ]; then
    printf '%s' "$(green "$ip")"
  else
    printf '%s' "$(yellow 'unavailable')"
  fi
}

unit_name() {
  case "$1" in
    *.service) printf '%s' "$1" ;;
    *) printf '%s.service' "$1" ;;
  esac
}

user_unit_state() {
  local unit state sub

  unit=$(unit_name "$1")
  need_cmd systemctl || {
    printf 'unavailable'
    return 0
  }

  state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  state=$(printf '%s\n' "$state" | sed -n '1p')

  case "$state" in
    active)
      sub=$(systemctl --user show "$unit" --property=SubState --value 2>/dev/null | sed -n '1p')
      if [ -n "$sub" ] && [ "$sub" != "$state" ]; then
        printf '%s (%s)' "$state" "$sub"
      else
        printf '%s' "$state"
      fi
      ;;
    '')
      printf 'unknown'
      ;;
    *)
      printf '%s' "$state"
      ;;
  esac
}

monitor_service_badge() {
  local state="${1:-}"

  case "$state" in
    active*)
      printf '%s' "$(green "$state")"
      ;;
    activating*|reloading*|unknown|unavailable)
      printf '%s' "$(yellow "$state")"
      ;;
    *)
      printf '%s' "$(red "$state")"
      ;;
  esac
}

latest_health_result() {
  local line ok fail text

  [ -f "$HEALTH_LOG" ] || {
    printf '%s' "$(dim 'none')"
    return 0
  }

  line=$(tail -1 "$HEALTH_LOG" 2>/dev/null || true)
  [ -n "$line" ] || {
    printf '%s' "$(dim 'none')"
    return 0
  }

  text=$(printf '%s\n' "$line" | sed -n 's/^[0-9-]\{10\} [0-9:]\{8\} //p')
  ok=$(printf '%s\n' "$line" | sed -n 's/.*health: \([0-9][0-9]*\) ok, \([0-9][0-9]*\) fail.*/\1/p')
  fail=$(printf '%s\n' "$line" | sed -n 's/.*health: \([0-9][0-9]*\) ok, \([0-9][0-9]*\) fail.*/\2/p')

  if [ -n "$ok" ] && [ -n "$fail" ]; then
    text="${ok} ok, ${fail} fail"
    if [ "$fail" -eq 0 ]; then
      printf '%s' "$(green "$text")"
    else
      printf '%s' "$(red "$text")"
    fi
  else
    printf '%s' "$(dim "${text:-none}")"
  fi
}

latest_health_timestamp() {
  local line ts

  [ -s "$HEALTH_LOG" ] || {
    printf '%s' "$(yellow 'unavailable')"
    return 0
  }

  line=$(tail -1 "$HEALTH_LOG" 2>/dev/null || true)
  [ -n "$line" ] || {
    printf '%s' "$(yellow 'unavailable')"
    return 0
  }

  ts=$(printf '%s\n' "$line" | sed -n 's/^\([0-9-]\{10\} [0-9:]\{8\}\).*/\1/p')
  if [ -n "$ts" ]; then
    printf '%s' "$ts"
  else
    printf '%s' "$(yellow 'unknown')"
  fi
}

local_disk_usage_percent() {
  df -P / 2>/dev/null | awk '
    NR == 2 {
      gsub("%", "", $5)
      print $5 + 0
      found = 1
    }
    END {
      if (!found) {
        exit 1
      }
    }
  '
}

disk_usage_badge() {
  local pct="${1:-}"

  case "$pct" in
    ''|*[!0-9]*)
      pct=$(local_disk_usage_percent 2>/dev/null || true)
      ;;
  esac

  case "$pct" in
    ''|*[!0-9]*)
      printf '%s' "$(yellow 'unavailable')"
      ;;
    *)
      if [ "$pct" -ge 90 ]; then
        printf '%s' "$(red "${pct}%")"
      elif [ "$pct" -ge 80 ]; then
        printf '%s' "$(yellow "${pct}%")"
      else
        printf '%s' "$(green "${pct}%")"
      fi
      ;;
  esac
}

resolved_task_queue_path() {
  local candidate

  if [ -n "${DWS_TASK_QUEUE_PATH:-}" ]; then
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

queue_count_badge() {
  local label="${1:-}" count="${2:-0}"

  case "$label" in
    pending)
      if [ "$count" -eq 0 ]; then
        printf '%s' "$(green 'pending=0')"
      else
        printf '%s' "$(cyan "pending=${count}")"
      fi
      ;;
    in_progress)
      if [ "$count" -eq 0 ]; then
        printf '%s' "$(dim 'in_progress=0')"
      else
        printf '%s' "$(yellow "in_progress=${count}")"
      fi
      ;;
    completed)
      printf '%s' "$(dim "completed=${count}")"
      ;;
    other)
      if [ "$count" -eq 0 ]; then
        printf '%s' ''
      else
        printf '%s' "$(yellow "other=${count}")"
      fi
      ;;
    total)
      printf '%s' "$(dim "total=${count}")"
      ;;
  esac
}

planner_queue_header_summary() {
  local path counts pending in_progress completed total last_reconciled other

  path=$(resolved_task_queue_path)

  if counts=$(planner_queue_counts "$path"); then
    IFS=$'\t' read -r pending in_progress completed total last_reconciled <<<"$counts"
    other=$((total - pending - in_progress - completed))
    printf '%s  %s  %s  %s' \
      "$(queue_count_badge pending "$pending")" \
      "$(queue_count_badge in_progress "$in_progress")" \
      "$(queue_count_badge completed "$completed")" \
      "$(queue_count_badge total "$total")"
    if [ "$other" -gt 0 ]; then
      printf '  %s' "$(queue_count_badge other "$other")"
    fi
    return 0
  fi

  case $? in
    2) printf '%s' "$(dim 'missing')" ;;
    3) printf '%s' "$(yellow 'empty')" ;;
    4) printf '%s' "$(yellow 'invalid')" ;;
    5) printf '%s' "$(yellow 'parser missing')" ;;
    *) printf '%s' "$(yellow 'unavailable')" ;;
  esac
}

header_session_count() {
  local body="${1:-}" count

  if [ -n "$body" ]; then
    count=$(jq -r '(.sessions // []) | length' <<<"$body" 2>/dev/null || true)
  else
    count='0'
  fi

  case "$count" in
    ''|*[!0-9]*) count='0' ;;
  esac

  printf '%s\n' "$count"
}

key_status() {
  local body="${1:-}" loaded=''

  if [ -n "$body" ]; then
    loaded=$(jq -r '.foundry_key.loaded // ""' <<<"$body" 2>/dev/null || true)
  fi

  if [ "$loaded" = "true" ] || [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    printf '%s' "$(green 'ok')"
  else
    printf '%s' "$(red 'missing')"
  fi
}

render_header() {
  local body="${1:-}"
  local count disk_percent tailscale_ip monitor_state

  count=$(header_session_count "$body")
  if [ -n "$body" ]; then
    disk_percent=$(jq -r '.vm.disk_percent // ""' <<<"$body" 2>/dev/null || true)
  else
    disk_percent=''
  fi
  tailscale_ip=$(header_tailscale_ip "$body")
  monitor_state=$(user_unit_state "$MONITOR_SERVICE_NAME")

  printf '  %s | %s\n' "$(bold 'dev-workspace')" "$(host_info)"
  printf '  sessions: %s\n' "$(active_session_summary "$count")"
  printf '  tailnet:  %s\n' "$(tailscale_ip_badge "$tailscale_ip")"
  printf '  monitor:  %s\n' "$(monitor_service_badge "$monitor_state")"
  printf '  health:   check=%s  result=%s  key=%s\n' \
    "$(latest_health_timestamp)" \
    "$(latest_health_result)" \
    "$(key_status "$body")"
  printf '  usage:    disk=%s used\n' "$(disk_usage_badge "$disk_percent")"
  printf '  queue:    %s\n' "$(planner_queue_header_summary)"
}

planner_artifact_state() {
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

planner_artifact_status() {
  local path="$1" stale_after="${2:-0}"
  local state age

  state=$(planner_artifact_state "$path" "$stale_after")
  age=$(file_age_summary "$path" || true)

  case "$state" in
    fresh) printf '%s' "$(green "fresh")" ;;
    stale) printf '%s' "$(yellow "stale")" ;;
    missing) printf '%s' "$(dim "missing")"; return 0 ;;
    empty) printf '%s' "$(yellow "empty")"; return 0 ;;
    present) printf '%s' "$(green "present")"; return 0 ;;
    *) printf '%s' "$(yellow "$state")"; return 0 ;;
  esac

  if [ -n "$age" ]; then
    printf ' %s' "$(dim "$age")"
  fi
}

planner_queue_counts() {
  local path="${1:-}"

  if [ -z "$path" ]; then
    path=$(resolved_task_queue_path)
  fi

  need_cmd jq || return 5
  [ -e "$path" ] || return 2
  [ -s "$path" ] || return 3
  jq -r '
    (.tasks // []) as $tasks |
    [
      ($tasks | map(select((.status // "") == "pending")) | length),
      ($tasks | map(select((.status // "") == "in_progress")) | length),
      ($tasks | map(select((.status // "") == "completed")) | length),
      ($tasks | length),
      (.last_reconciled_at // "")
    ] | @tsv
  ' "$path" 2>/dev/null || return 4
}

planner_queue_motd() {
  local path counts pending in_progress completed total last_reconciled state

  path=$(resolved_task_queue_path)
  state=$(planner_artifact_state "$path" "$PLANNER_STALE_SECONDS")
  if counts=$(planner_queue_counts "$path"); then
    IFS=$'\t' read -r pending in_progress completed total last_reconciled <<<"$counts"
    if [ "$state" = "stale" ]; then
      printf 'queue=stale,pending=%s,in_progress=%s,completed=%s' "$pending" "$in_progress" "$completed"
    else
      printf 'queue=pending=%s,in_progress=%s,completed=%s' "$pending" "$in_progress" "$completed"
    fi
    return 0
  fi

  case $? in
    2) printf 'queue=missing' ;;
    3) printf 'queue=empty' ;;
    4) printf 'queue=invalid' ;;
    5) printf 'queue=jq-missing' ;;
    *) printf 'queue=unavailable' ;;
  esac
}

render_planner() {
  local path queue_counts queue_status queue_error
  local pending in_progress completed total last_reconciled

  path=$(resolved_task_queue_path)
  bold "  planner"; echo
  queue_status=$(planner_artifact_status "$path" "$PLANNER_STALE_SECONDS")
  if queue_counts=$(planner_queue_counts "$path"); then
    IFS=$'\t' read -r pending in_progress completed total last_reconciled <<<"$queue_counts"
    printf '    queue:  pending=%s  in_progress=%s  completed=%s  total=%s  %s\n' \
      "$pending" "$in_progress" "$completed" "$total" "$queue_status"
  else
    queue_error=$?
    case "$queue_error" in
      2|3)
        printf '    queue:  %s\n' "$queue_status"
        ;;
      4)
        printf '    queue:  %s  %s\n' "$(yellow "invalid json")" "$queue_status"
        ;;
      5)
        printf '    queue:  %s\n' "$(yellow "jq missing")"
        ;;
      *)
        printf '    queue:  %s\n' "$(yellow "unavailable")"
        ;;
    esac
  fi
  printf '    status: %s\n' "$(planner_artifact_status "$PLANNER_STATUS_PATH" "$PLANNER_STALE_SECONDS")"
  printf '    state:  %s\n' "$(planner_artifact_status "$PLANNER_STATE_PATH" "$PLANNER_STALE_SECONDS")"
  printf '    log:    %s\n' "$(planner_artifact_status "$PLANNER_LOG_PATH" "$PLANNER_LOG_STALE_SECONDS")"
}

payload() {
  local body
  need_cmd curl || { printf 'missing curl\n' >&2; return 1; }
  need_cmd jq || { printf 'missing jq\n' >&2; return 1; }
  body=$(curl -fsS --max-time 2 "$STATUS_URL") || {
    printf 'orchestrator health unavailable: %s\n' "$STATUS_URL" >&2
    return 1
  }
  jq -e . >/dev/null 2>&1 <<<"$body" || {
    printf 'orchestrator health returned invalid json\n' >&2
    return 1
  }
  printf '%s\n' "$body"
}

render_motd() {
  local body="${1:-}" hostname sessions projects dirty tailscale_ip queue_summary

  queue_summary=$(planner_queue_motd)

  if [ -n "$body" ]; then
    hostname=$(jq -r '.vm.hostname // "-"' <<<"$body")
    sessions=$(jq -r '(.sessions // []) | length' <<<"$body")
    projects=$(jq -r '(.projects // []) | length' <<<"$body")
    dirty=$(jq -r '[.projects[]? | select(.dirty)] | length' <<<"$body")
    tailscale_ip=$(jq -r '.tailscale.ip // ""' <<<"$body")
    printf '  orchestrator: %s  host=%s  sessions=%s  projects=%s  dirty=%s' "$(green "ok")" "$hostname" "$sessions" "$projects" "$dirty"
    if [ -n "$tailscale_ip" ]; then
      printf '  tailnet=%s' "$tailscale_ip"
    fi
  else
    printf '  orchestrator: %s  source=%s' "$(red "unavailable")" "$STATUS_URL"
  fi
  printf '  %s' "$queue_summary"
  printf '\n'
}

render_full() {
  local body="${1:-}"
  local count uptime disk_percent memory_percent hostname tailscale_ip
  local tailscale_connected foundry_loaded project_count

  render_header "$body"
  echo

  if [ -n "$body" ]; then
    echo "  $(green "orchestrator health API")"
    printf '    source: %s\n' "$STATUS_URL"
    echo

    bold "  active sessions"; echo
    count=$(jq -r '(.sessions // []) | length' <<<"$body")
    if [ "$count" -gt 0 ]; then
      jq -r '.sessions[]?' <<<"$body" | sed 's/^/    /'
    else
      dim "    (none)"; echo
    fi
    echo

    bold "  projects"; echo
    project_count=$(jq -r '(.projects // []) | length' <<<"$body")
    if [ "$project_count" -gt 0 ]; then
      while IFS=$'\t' read -r name branch dirty; do
        [ -n "$name" ] || continue
        if [ "$dirty" = "true" ]; then
          printf '    %-28s %s %s\n' "$name" "${branch:--}" "$(yellow "*dirty")"
        else
          printf '    %-28s %s\n' "$name" "${branch:--}"
        fi
      done < <(jq -r '.projects[]? | [.name, (.branch // "-"), (if .dirty then "true" else "false" end)] | @tsv' <<<"$body")
    else
      dim "    (none)"; echo
    fi
    echo

    render_planner
    echo

    hostname=$(jq -r '.vm.hostname // "-"' <<<"$body")
    uptime=$(jq -r '.vm.uptime // "-"' <<<"$body")
    disk_percent=$(jq -r '.vm.disk_percent // 0' <<<"$body")
    memory_percent=$(jq -r '.vm.memory_percent // 0' <<<"$body")
    foundry_loaded=$(jq -r '.foundry_key.loaded // false' <<<"$body")
    tailscale_connected=$(jq -r '.tailscale.connected // false' <<<"$body")
    tailscale_ip=$(jq -r '.tailscale.ip // ""' <<<"$body")

    bold "  system"; echo
    printf '    host:   %s\n' "$hostname"
    printf '    uptime: %s\n' "$uptime"
    printf '    disk:   %s%% used\n' "$disk_percent"
    printf '    mem:    %s%% used\n' "$memory_percent"
    if [ "$foundry_loaded" = "true" ]; then
      printf '    key:    %s\n' "$(green "ok")"
    else
      printf '    key:    %s\n' "$(red "missing")"
    fi
    echo

    bold "  tailnet"; echo
    if [ "$tailscale_connected" = "true" ]; then
      if [ -n "$tailscale_ip" ]; then
        printf '    connected: %s (%s)\n' "$(green "yes")" "$tailscale_ip"
      else
        printf '    connected: %s\n' "$(green "yes")"
      fi
    else
      printf '    connected: %s\n' "$(red "no")"
    fi
  else
    red "orchestrator health unavailable"; echo
    printf '  source: %s\n' "$STATUS_URL"
    echo
    render_planner
  fi
}

main() {
  local mode body status
  mode="${1:-}"
  case "$mode" in
    ''|--json|--motd) ;;
    -h|--help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  status=0
  if body=$(payload); then
    :
  else
    status=1
    body=""
  fi

  case "$mode" in
    --json)
      if [ "$status" -eq 0 ]; then
        printf '%s\n' "$body"
      else
        printf '{"error":"orchestrator health unavailable","url":"%s"}\n' "$STATUS_URL"
      fi
      ;;
    --motd) render_motd "$body" ;;
    *) render_full "$body" ;;
  esac

  return "$status"
}

main "$@"
