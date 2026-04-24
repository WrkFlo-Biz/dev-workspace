#!/usr/bin/env bash
# dws-launcher.sh — runs on SSH login to the dev-workspace VM.
# Two-step picker: project -> model/tool, wrapped in tmux for session persistence.
# If you disconnect (phone sleep, network drop), reconnect and your session is alive.
#
# Escape hatches:
#   - press q or ^C at the prompt to drop to a plain shell
#   - set SKIP_LAUNCHER=1 before SSH (or in Termius host env) to disable

set -u

LAUNCHER_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$LAUNCHER_DIR/.." && pwd)
SCRIPT_DIR="$LAUNCHER_DIR"
LAUNCHER_ENV_PATH="${DWS_LAUNCHER_ENV_PATH:-$LAUNCHER_DIR/dws-env.sh}"
FOUNDRY_ENV_PATH="${DWS_FOUNDRY_ENV_PATH:-$HOME/.config/wrkflo/foundry.env}"
FOUNDRY_ENV_STATE="unknown"
LAUNCHER_ENV_STATE="builtin"

init_launcher_env_defaults() {
  export MAC_GUI_URL="${MAC_GUI_URL:-http://100.78.207.22:9223}"
  export MAC_CDP_URL="${MAC_CDP_URL:-http://100.78.207.22:9222}"
  export MAC_SSH_HOST="${MAC_SSH_HOST:-mosestut@100.78.207.22}"

  PROJECTS=(
    global-sentinel
    wrkflo-voice-agents-ops
    openclaw-prod
    global-sentinel-azure-quantum
    wrkflo-orchestrator
    dev-workspace
  )

  color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
  bold() { color '1' "$1"; }
  dim() { color '2' "$1"; }
  green() { color '32' "$1"; }
  cyan() { color '36' "$1"; }
  yellow() { color '33' "$1"; }
  red() { color '31' "$1"; }

  proj_name() {
    case "$1" in
      [1-6]) printf '%s\n' "${PROJECTS[$(($1 - 1))]}" ;;
      *) printf '\n' ;;
    esac
  }

  proj_short() {
    case "$1" in
      global-sentinel) echo "gs" ;;
      wrkflo-voice-agents-ops) echo "voice" ;;
      openclaw-prod) echo "oclaw" ;;
      global-sentinel-azure-quantum) echo "gsaq" ;;
      wrkflo-orchestrator) echo "orch" ;;
      dev-workspace) echo "dws" ;;
      *) echo "proj" ;;
    esac
  }

  profile_for() {
    case "$1" in
      1) echo "foundry-5_4" ;;
      2) echo "foundry-5_2" ;;
      3) echo "foundry-codex" ;;
      4) echo "foundry-mini" ;;
      5) echo "foundry-5-mini" ;;
      6) echo "foundry-4o" ;;
      7) echo "foundry-opus" ;;
      8) echo "foundry-sonnet" ;;
      9) echo "foundry-haiku" ;;
      *) echo "" ;;
    esac
  }

  model_label() {
    case "$1" in
      1) echo "5-4" ;;
      2) echo "5-2" ;;
      3) echo "codex" ;;
      4) echo "mini" ;;
      5) echo "5mini" ;;
      6) echo "4o" ;;
      7) echo "opus" ;;
      8) echo "sonnet" ;;
      9) echo "haiku" ;;
      c|C) echo "claude" ;;
      *) echo "?" ;;
    esac
  }
}

load_launcher_env() {
  local rc=0

  if [ ! -r "$LAUNCHER_ENV_PATH" ]; then
    LAUNCHER_ENV_STATE="missing"
    return 1
  fi

  set +u
  # shellcheck source=/dev/null
  . "$LAUNCHER_ENV_PATH"
  rc=$?
  set -u

  if [ "$rc" -ne 0 ]; then
    LAUNCHER_ENV_STATE="error"
    return "$rc"
  fi

  LAUNCHER_ENV_STATE="loaded"
  return 0
}

load_foundry_env() {
  local rc=0

  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    FOUNDRY_ENV_STATE="preloaded"
    return 0
  fi

  if [ ! -f "$FOUNDRY_ENV_PATH" ]; then
    FOUNDRY_ENV_STATE="missing"
    return 1
  fi

  set +u
  # shellcheck source=/dev/null
  . "$FOUNDRY_ENV_PATH"
  rc=$?
  set -u

  if [ "$rc" -ne 0 ]; then
    FOUNDRY_ENV_STATE="error"
    return "$rc"
  fi

  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    FOUNDRY_ENV_STATE="loaded"
    return 0
  fi

  FOUNDRY_ENV_STATE="empty"
  return 1
}

DWS_LAUNCHER_CMD="${1:-}"
case "$DWS_LAUNCHER_CMD" in
  status) shift ;;
  *) DWS_LAUNCHER_CMD="" ;;
esac

if [ "$DWS_LAUNCHER_CMD" != "status" ]; then
  [ -t 0 ] || return 0 2>/dev/null || exit 0
  [ -z "${SKIP_LAUNCHER:-}" ] || return 0 2>/dev/null || exit 0
  [ -z "${DWS_LAUNCHER_RAN:-}" ] || return 0 2>/dev/null || exit 0
  export DWS_LAUNCHER_RAN=1
fi

load_foundry_env >/dev/null 2>&1 || true
init_launcher_env_defaults
load_launcher_env >/dev/null 2>&1 || true
SESSIONS_TOOL="$SCRIPT_DIR/dws-sessions.sh"
QUICK_TOOL="$SCRIPT_DIR/dws-quick.sh"
HEALTH_LOG="/tmp/dws-health.log"
HEALTH_ALERT_LOG="/tmp/dws-health-alerts.log"
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-}"
ORCHESTRATOR_HEALTH_URL="${DWS_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"
STATUS_TOOL_REPO="${DWS_STATUS_TOOL_REPO:-$HOME/projects/dev-workspace/bin/dws-status.sh}"
MONITOR_SERVICE_NAME="${DWS_MONITOR_SERVICE_NAME:-dws-task-monitor}"

# ── Helpers ──

hr() { local w; w=$(tput cols 2>/dev/null || echo 40); printf '%*s\n' "$w" '' | tr ' ' '─'; }

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

tmux_available() {
  have_cmd tmux
}

host_info() {
  local h who
  h=$(hostname -s 2>/dev/null || echo "?")
  who=$(whoami)
  bold "$who@$h"
}

key_status() {
  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    green "ok"
  else
    red "missing"
  fi
}

foundry_key_ready() {
  [ -n "${AZURE_OPENAI_API_KEY:-}" ]
}

foundry_key_hint() {
  case "$FOUNDRY_ENV_STATE" in
    preloaded)
      printf '%s' "AZURE_OPENAI_API_KEY is already loaded"
      ;;
    loaded)
      printf '%s' "loaded key from ${FOUNDRY_ENV_PATH}"
      ;;
    missing)
      printf '%s' "missing ${FOUNDRY_ENV_PATH}"
      ;;
    empty)
      printf '%s' "${FOUNDRY_ENV_PATH} did not export AZURE_OPENAI_API_KEY"
      ;;
    error)
      printf '%s' "could not load ${FOUNDRY_ENV_PATH}"
      ;;
    *)
      printf '%s' "AZURE_OPENAI_API_KEY is unavailable"
      ;;
  esac
}

show_openai_profile_warning() {
  yellow "  OpenAI profiles unavailable"; echo
  dim "  $(foundry_key_hint)"; echo
  dim "  choose Claude or plain shell until the key is restored"; echo
  sleep 1
}

active_session_summary() {
  local n="${1:-0}" label
  if [ "$n" -eq 1 ]; then
    label="1 active"
  else
    label="$n active"
  fi
  if [ "$n" -gt 0 ]; then
    printf '%s' "$(cyan "$label")"
  else
    printf '%s' "$(dim "$label")"
  fi
}

tailscale_ip_from_payload() {
  local payload="${1:-}"

  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.tailscale.ip // ""' <<<"$payload" 2>/dev/null || true
}

tailscale_ip_value() {
  local payload="${1:-}" ip=""

  if command -v tailscale >/dev/null 2>&1; then
    ip=$(tailscale ip -4 2>/dev/null | sed -n '1p' || true)
  fi

  if [ -z "$ip" ]; then
    ip=$(tailscale_ip_from_payload "$payload")
  fi

  printf '%s\n' "$ip"
}

tailscale_ip_badge() {
  local ip="${1:-}"

  if [ -n "$ip" ]; then
    printf '%s' "$(green "$ip")"
  else
    printf '%s' "$(yellow "unavailable")"
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
  command -v systemctl >/dev/null 2>&1 || {
    printf '%s' "unavailable"
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
      printf '%s' "unknown"
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
  [ -f "$HEALTH_LOG" ] || { printf '%s' "$(dim "none")"; return; }
  line=$(tail -1 "$HEALTH_LOG" 2>/dev/null)
  [ -n "$line" ] || { printf '%s' "$(dim "none")"; return; }
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
  [ -s "$HEALTH_LOG" ] || { printf '%s' "$(yellow "unavailable")"; return; }
  line=$(tail -1 "$HEALTH_LOG" 2>/dev/null || true)
  [ -n "$line" ] || { printf '%s' "$(yellow "unavailable")"; return; }
  ts=$(printf '%s\n' "$line" | sed -n 's/^\([0-9-]\{10\} [0-9:]\{8\}\).*/\1/p')
  if [ -n "$ts" ]; then
    printf '%s' "$ts"
  else
    printf '%s' "$(yellow "unknown")"
  fi
}

disk_usage_percent_from_payload() {
  local payload="${1:-}" pct

  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  pct=$(jq -r '.vm.disk_percent // empty' <<<"$payload" 2>/dev/null || true)
  case "$pct" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$pct" ;;
  esac
}

disk_usage_percent() {
  local payload="${1:-}" pct=""

  pct=$(df -P / 2>/dev/null | awk '
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
  ' || true)

  case "$pct" in
    ''|*[!0-9]*) pct=$(disk_usage_percent_from_payload "$payload" || true) ;;
  esac

  case "$pct" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$pct" ;;
  esac
}

disk_usage_badge() {
  local payload="${1:-}" pct
  pct=$(disk_usage_percent "$payload" 2>/dev/null || true)
  case "$pct" in
    ''|*[!0-9]*)
      printf '%s' "$(yellow "unavailable")"
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

  if [ -n "$TASK_QUEUE_PATH" ]; then
    printf '%s\n' "$TASK_QUEUE_PATH"
    return 0
  fi

  for candidate in \
    "$REPO_ROOT/.state/task-queue.json" \
    "$HOME/projects/dev-workspace/.state/task-queue.json" \
    "/tmp/task-queue.json"
  do
    if [ -e "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$REPO_ROOT/.state/task-queue.json"
}

task_queue_status_counts() {
  local path="${1:-}"

  [ -e "$path" ] || return 2
  [ -s "$path" ] || return 3

  if command -v jq >/dev/null 2>&1; then
    jq -r '
      reduce (.tasks // [])[]? as $task (
        {"pending": 0, "in_progress": 0, "completed": 0, "other": 0};
        (($task.status // "") | ascii_downcase) as $status
        | if $status == "pending" then .pending += 1
          elif $status == "in_progress" then .in_progress += 1
          elif $status == "completed" then .completed += 1
          else .other += 1
          end
      )
      | [.pending, .in_progress, .completed, .other, (.pending + .in_progress + .completed + .other)]
      | @tsv
    ' "$path" 2>/dev/null || return 4
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    raise SystemExit(4)

tasks = data.get("tasks") or []
counts = {
    "pending": 0,
    "in_progress": 0,
    "completed": 0,
    "other": 0,
}

for task in tasks:
    status = str(task.get("status") or "").lower()
    if status in ("pending", "in_progress", "completed"):
        counts[status] += 1
    else:
        counts["other"] += 1

total = counts["pending"] + counts["in_progress"] + counts["completed"] + counts["other"]
print(
    f"{counts['pending']}\t{counts['in_progress']}\t"
    f"{counts['completed']}\t{counts['other']}\t{total}"
)
PY
    return $?
  fi

  return 5
}

queue_count_badge() {
  local label="${1:-}" count="${2:-0}"

  case "$label" in
    pending)
      if [ "$count" -eq 0 ]; then
        printf '%s' "$(green "pending=0")"
      else
        printf '%s' "$(cyan "pending=${count}")"
      fi
      ;;
    in_progress)
      if [ "$count" -eq 0 ]; then
        printf '%s' "$(dim "in_progress=0")"
      else
        printf '%s' "$(yellow "in_progress=${count}")"
      fi
      ;;
    completed)
      printf '%s' "$(dim "completed=${count}")"
      ;;
    other)
      if [ "$count" -eq 0 ]; then
        printf '%s' ""
      else
        printf '%s' "$(yellow "other=${count}")"
      fi
      ;;
    total)
      printf '%s' "$(dim "total=${count}")"
      ;;
  esac
}

task_queue_header_summary() {
  local path counts pending in_progress completed other total status

  path=$(resolved_task_queue_path)

  counts=$(task_queue_status_counts "$path")
  status=$?

  if [ "$status" -eq 0 ]; then
    IFS=$'\t' read -r pending in_progress completed other total <<EOF
$counts
EOF
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

  case "$status" in
    2) printf '%s' "$(dim "missing")" ;;
    3) printf '%s' "$(yellow "empty")" ;;
    4) printf '%s' "$(yellow "invalid")" ;;
    5) printf '%s' "$(yellow "parser missing")" ;;
    *) printf '%s' "$(yellow "unavailable")" ;;
  esac
}

print_status_header() {
  local sc="${1:-0}" payload="${2:-}" tailnet_ip monitor_state

  tailnet_ip=$(tailscale_ip_value "$payload")
  monitor_state=$(user_unit_state "$MONITOR_SERVICE_NAME")
  printf '  %s · %s\n' "$(bold '⎈ dev-workspace')" "$(host_info)"
  printf '  sessions: %s\n' "$(active_session_summary "$sc")"
  printf '  tailnet:  %s\n' "$(tailscale_ip_badge "$tailnet_ip")"
  printf '  monitor:  %s\n' "$(monitor_service_badge "$monitor_state")"
  printf '  health:   check=%s  result=%s  key=%s\n' \
    "$(latest_health_timestamp)" \
    "$(latest_health_result)" \
    "$(key_status)"
  printf '  usage:    disk=%s used\n' "$(disk_usage_badge "$payload")"
  printf '  queue:    %s\n' "$(task_queue_header_summary)"
}

model_arg() {
  case "$1" in
    1) echo "5.4" ;;
    2) echo "5.2" ;;
    3) echo "codex" ;;
    4) echo "mini" ;;
    5) echo "5mini" ;;
    6) echo "4o" ;;
    7) echo "opus" ;;
    8) echo "sonnet" ;;
    9) echo "haiku" ;;
    c|C) echo "claude" ;;
    *) echo "" ;;
  esac
}

refresh_health_status() {
  command -v dws-health-check.sh >/dev/null 2>&1 || return 0
  dws-health-check.sh >/dev/null 2>&1 || true
}

status_tool_path() {
  local candidate
  for candidate in "${DWS_STATUS_TOOL:-}" "$LAUNCHER_DIR/dws-status.sh" "$STATUS_TOOL_REPO"; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

orchestrator_health_payload() {
  local payload
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  payload=$(curl -fsS --max-time 2 "$ORCHESTRATOR_HEALTH_URL" 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1
  jq -e . >/dev/null 2>&1 <<<"$payload" || return 1
  printf '%s\n' "$payload"
}

status_usage() {
  cat <<EOF
usage: $(basename "$0") status [--json|--motd]
EOF
}

status_motd_orchestrator() {
  local payload="$1" hostname sessions projects dirty tailscale_ip
  hostname=$(jq -r '.vm.hostname // "-"' <<<"$payload")
  sessions=$(jq -r '(.sessions // []) | length' <<<"$payload")
  projects=$(jq -r '(.projects // []) | length' <<<"$payload")
  dirty=$(jq -r '[.projects[]? | select(.dirty)] | length' <<<"$payload")
  tailscale_ip=$(jq -r '.tailscale.ip // ""' <<<"$payload")
  printf '  orchestrator: %s  host=%s  sessions=%s  projects=%s  dirty=%s' "$(green "ok")" "$hostname" "$sessions" "$projects" "$dirty"
  if [ -n "$tailscale_ip" ]; then
    printf '  tailnet=%s' "$tailscale_ip"
  fi
  printf '\n'
}

shell_tailnet_preview() {
  local out=""

  if ! have_cmd tailscale; then
    dim "    (tailscale CLI unavailable)"; echo
    return 0
  fi

  out=$(tailscale status 2>&1 || true)
  if [ -z "$out" ] && command -v sudo >/dev/null 2>&1; then
    out=$(sudo -n tailscale status 2>&1 || true)
  fi

  out=$(printf '%s\n' "$out" | sed -n '1,6p' | sed '/^[[:space:]]*$/d')
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/    /'
  else
    dim "    (tailscale status unavailable)"; echo
  fi
}

shell_uptime_value() {
  local value

  value=$(uptime -p 2>/dev/null || uptime 2>/dev/null || true)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$(yellow "unavailable")"
  fi
}

shell_disk_usage_value() {
  local value

  value=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5" used)"}' || true)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$(yellow "unavailable")"
  fi
}

shell_memory_usage_value() {
  local value

  value=$(free -h 2>/dev/null | awk 'NR==2{print $3"/"$2" ("int($3/$2*100)"% used)"}' || true)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$(yellow "unavailable")"
  fi
}

show_local_projects() {
  local d found=0 name branch dirty

  for d in "$HOME"/projects/*/; do
    [ -d "$d" ] || continue
    found=1
    name=$(basename "$d")
    branch=$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null || echo "-")
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | head -1)
    if [ -n "$dirty" ]; then
      printf "    %-28s %s %s\n" "$name" "$branch" "$(yellow "*dirty")"
    else
      printf "    %-28s %s\n" "$name" "$branch"
    fi
  done

  if [ "$found" -eq 0 ]; then
    dim "    (none)"; echo
  fi
}

status_command() {
  local mode="${1:-}" payload tool
  case "$mode" in
    ""|--json|--motd|-h|--help) ;;
    *) status_usage >&2; return 2 ;;
  esac
  if [ "$mode" = "-h" ] || [ "$mode" = "--help" ]; then
    status_usage
    return 0
  fi
  tool=$(status_tool_path || true)
  if [ -n "$tool" ]; then
    if [ -n "$mode" ]; then
      if "$tool" "$mode"; then
        return 0
      fi
    else
      if "$tool"; then
        return 0
      fi
      yellow "external status tool failed; falling back"; echo
      echo
    fi
  fi
  refresh_health_status
  payload=$(orchestrator_health_payload || true)
  if [ -z "$payload" ]; then
    case "$mode" in
      --json)
        printf '{"error":"orchestrator health unavailable","url":"%s"}\n' "$ORCHESTRATOR_HEALTH_URL"
        ;;
      --motd)
        printf '  orchestrator: %s  source=%s\n' "$(red "unavailable")" "$ORCHESTRATOR_HEALTH_URL"
        ;;
      *)
        yellow "orchestrator health API unavailable; using shell heuristics"; echo
        echo
        status_page_shell
        ;;
    esac
    case "$mode" in
      "" ) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$mode" in
    --json) printf '%s\n' "$payload" ;;
    --motd) status_motd_orchestrator "$payload" ;;
    *) status_page_orchestrator "$payload" ;;
  esac
}

show_health_tail() {
  [ -f "$HEALTH_LOG" ] || { dim "    (no health checks logged)"; echo; return; }
  tail -5 "$HEALTH_LOG" | sed 's/^/    /'
}

show_health_alerts() {
  local cut alerts
  [ -f "$HEALTH_ALERT_LOG" ] || { dim "    (no alerts in last 24h)"; echo; return; }
  if ! have_cmd date || ! have_cmd awk; then
    dim "    (alert scan unavailable)"; echo
    return 0
  fi
  cut=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
  if [ -z "$cut" ]; then
    dim "    (alert scan unavailable)"; echo
    return 0
  fi
  alerts=$(awk -v cut="$cut" 'index($0, "ALERT") && substr($0, 1, 19) >= cut' "$HEALTH_ALERT_LOG" 2>/dev/null || true)
  if [ -n "$alerts" ]; then
    printf '%s\n' "$alerts" | sed 's/^/    /'
  else
    dim "    (no alerts in last 24h)"; echo
  fi
}

status_page_health_logs() {
  echo
  bold "  health"; echo
  dim "    recent checks"; echo
  show_health_tail
  dim "    alerts (last 24h)"; echo
  show_health_alerts
}

status_page_shell() {
  local sc
  sc=$(session_count)
  print_status_header "$sc"
  echo
  bold "  active sessions"; echo
  if [ "$sc" -gt 0 ]; then
    list_sessions | sed 's/^/    /'
  else
    dim "    (none)"; echo
  fi
  echo
  bold "  projects"; echo
  show_local_projects
  echo
  bold "  system"; echo
  printf "    uptime: %s\n" "$(shell_uptime_value)"
  printf "    disk:   %s\n" "$(shell_disk_usage_value)"
  printf "    mem:    %s\n" "$(shell_memory_usage_value)"
  printf "    key:    %s\n" "$(key_status)"
  echo
  bold "  tailnet"; echo
  shell_tailnet_preview
  status_page_health_logs
}

status_page_orchestrator() {
  local payload="$1" count uptime disk_percent memory_percent hostname tailscale_ip
  local tailscale_connected foundry_loaded project_count
  count=$(jq -r '(.sessions // []) | length' <<<"$payload")
  print_status_header "$count" "$payload"
  echo
  echo "  $(green "orchestrator health API")"
  printf "    source: %s\n" "$ORCHESTRATOR_HEALTH_URL"
  echo
  bold "  active sessions"; echo
  if [ "$count" -gt 0 ]; then
    jq -r '.sessions[]?' <<<"$payload" | sed 's/^/    /'
  else
    dim "    (none)"; echo
  fi
  echo
  bold "  projects"; echo
  project_count=$(jq -r '(.projects // []) | length' <<<"$payload")
  if [ "$project_count" -gt 0 ]; then
    while IFS=$'\t' read -r name branch dirty; do
      [ -n "$name" ] || continue
      if [ "$dirty" = "true" ]; then
        printf "    %-28s %s %s\n" "$name" "${branch:--}" "$(yellow "*dirty")"
      else
        printf "    %-28s %s\n" "$name" "${branch:--}"
      fi
    done < <(jq -r '.projects[]? | [.name, (.branch // "-"), (if .dirty then "true" else "false" end)] | @tsv' <<<"$payload")
  else
    dim "    (none)"; echo
  fi
  echo
  hostname=$(jq -r '.vm.hostname // "-"' <<<"$payload")
  uptime=$(jq -r '.vm.uptime // "-"' <<<"$payload")
  disk_percent=$(jq -r '.vm.disk_percent // 0' <<<"$payload")
  memory_percent=$(jq -r '.vm.memory_percent // 0' <<<"$payload")
  foundry_loaded=$(jq -r '.foundry_key.loaded // false' <<<"$payload")
  tailscale_connected=$(jq -r '.tailscale.connected // false' <<<"$payload")
  tailscale_ip=$(jq -r '.tailscale.ip // ""' <<<"$payload")
  bold "  system"; echo
  printf "    host:   %s\n" "$hostname"
  printf "    uptime: %s\n" "$uptime"
  printf "    disk:   %s%% used\n" "$disk_percent"
  printf "    mem:    %s%% used\n" "$memory_percent"
  if [ "$foundry_loaded" = "true" ]; then
    printf "    key:    %s\n" "$(green "ok")"
  else
    printf "    key:    %s\n" "$(red "missing")"
  fi
  echo
  bold "  tailnet"; echo
  if [ "$tailscale_connected" = "true" ]; then
    if [ -n "$tailscale_ip" ]; then
      printf "    connected: %s (%s)\n" "$(green "yes")" "$tailscale_ip"
    else
      printf "    connected: %s\n" "$(green "yes")"
    fi
  else
    printf "    connected: %s\n" "$(red "no")"
  fi
  status_page_health_logs
}

# ── tmux session management ──

list_sessions() {
  if [ -x "$SESSIONS_TOOL" ]; then
    "$SESSIONS_TOOL" list 2>/dev/null || true
    return 0
  fi

  if tmux_available; then
    tmux ls -F '#{session_name} #{?session_attached,attached,detached}' 2>/dev/null || true
  fi
}

session_count() {
  local count

  count=$(list_sessions | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || true)
  case "$count" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$count" ;;
  esac
}

session_names() {
  if [ -x "$SESSIONS_TOOL" ]; then
    list_sessions | awk '{print $1}'
    return 0
  fi

  if tmux_available; then
    tmux ls -F '#{session_name}' 2>/dev/null || true
  fi
}

resolve_session_pick() {
  local pick="${1:-}" name
  [ -n "$pick" ] || return 1

  if session_names | grep -Fx -- "$pick" >/dev/null 2>&1; then
    printf '%s\n' "$pick"
    return 0
  fi

  case "$pick" in
    ''|*[!0-9]*) return 1 ;;
    *)
      name=$(session_names | sed -n "${pick}p")
      [ -n "$name" ] || return 1
      printf '%s\n' "$name"
      ;;
  esac
}

attach_named_session() {
  local name="$1"

  if ! tmux_available; then
    yellow "  tmux unavailable"; echo
    return 1
  fi

  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$name"
  else
    exec tmux attach -t "$name"
  fi
}

launch_choice() {
  local proj="$1" choice="$2" short arg
  short=$(proj_short "$proj")
  arg=$(model_arg "$choice")
  if [ -n "$arg" ] && [ -x "$QUICK_TOOL" ]; then
    exec "$QUICK_TOOL" "$short" "$arg"
  fi
  return 1
}

# ── Workspace prompt injected into Codex/Claude ──

workspace_prompt() {
  local proj="$1"
  cat <<WEOF
Workspace root: \$HOME/projects.
Projects: global-sentinel, wrkflo-voice-agents-ops, openclaw-prod, global-sentinel-azure-quantum, wrkflo-orchestrator, dev-workspace.
Focus: $proj. Start there, inspect siblings under \$HOME/projects when asked.
Mac bridges: GUI=\$MAC_GUI_URL  CDP=\$MAC_CDP_URL  SSH=\$MAC_SSH_HOST
WEOF
}

# ── Launch into tmux ──

launch_tmux() {
  local proj="$1" tool="$2" session_name="$3"

  if [ ! -d "$HOME/projects/$proj" ]; then
    red "missing: ~/projects/$proj"; echo
    read -rp "press enter "
    return 1
  fi

  local base_cmd
  if [ "$tool" = "claude" ]; then
    base_cmd="claude --dangerously-skip-permissions"
  else
    base_cmd="codex --profile $tool --search --dangerously-bypass-approvals-and-sandbox"
  fi

  if ! tmux_available; then
    echo "  $(yellow "tmux unavailable") launching without session persistence..."
    sleep 0.3
    (
      export AZURE_OPENAI_API_KEY="${AZURE_OPENAI_API_KEY:-}"
      export MAC_GUI_URL="${MAC_GUI_URL:-}"
      export MAC_CDP_URL="${MAC_CDP_URL:-}"
      export MAC_SSH_HOST="${MAC_SSH_HOST:-}"
      export DWS_PRIMARY_PROJECT="$proj"
      cd "$HOME/projects/$proj" || exit 1
      bash -lc "$base_cmd"
    )
    return $?
  fi

  # Wrap in retry loop so crashes don't kill the tmux session
  local wrapped_cmd
  wrapped_cmd="export AZURE_OPENAI_API_KEY='${AZURE_OPENAI_API_KEY:-}'; \
export MAC_GUI_URL='${MAC_GUI_URL:-}'; \
export MAC_CDP_URL='${MAC_CDP_URL:-}'; \
export MAC_SSH_HOST='${MAC_SSH_HOST:-}'; \
export DWS_PRIMARY_PROJECT='$proj'; \
cd $HOME/projects/$proj; \
while true; do \
  $base_cmd; \
  echo; echo 'Session ended. [r]estart / [q]uit:'; \
  read -r _ch; \
  case \$_ch in r|R) continue ;; *) break ;; esac; \
done; \
exec bash -l"

  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "  $(green "reconnecting") to $session_name..."
    sleep 0.3
    exec tmux attach -t "$session_name"
  else
    echo "  $(green "launching") $session_name..."
    sleep 0.3
    exec tmux new-session -s "$session_name" -c "$HOME/projects/$proj" "$wrapped_cmd"
  fi
}

# ── Status page ──

status_page() {
  local orchestrator_payload tool
  refresh_health_status
  clear 2>/dev/null || true
  echo
  tool=$(status_tool_path || true)
  if [ -n "$tool" ]; then
    if "$tool"; then
      echo
      read -rp "  press enter to return "
      return
    fi
    echo
    yellow "  external status tool failed; falling back"; echo
    echo
  fi
  orchestrator_payload=$(orchestrator_health_payload || true)
  if [ -n "$orchestrator_payload" ]; then
    status_page_orchestrator "$orchestrator_payload"
  else
    yellow "  orchestrator health API unavailable; using shell heuristics"; echo
    echo
    status_page_shell
  fi
  echo
  read -rp "  press enter to return "
}

if [ "$DWS_LAUNCHER_CMD" = "status" ]; then
  status_command "$@"
  rc=$?
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return "$rc"
  fi
  exit "$rc"
fi

# ── Main loop ──

while :; do
  refresh_health_status
  sc=$(session_count)
  clear 2>/dev/null || true
  echo
  print_status_header "$sc"
  hr

  # Show active sessions if any exist
  if [ "$sc" -gt 0 ]; then
    echo
    bold "  Active sessions ($sc):"; echo
    list_sessions | sed 's/^/    /'
    echo
    cyan "  r"; echo -n "  reconnect to session"
    echo
    cyan "  k"; echo -n "  kill a session"
    echo
    cyan "  x"; echo -n "  cleanup sessions older than 24h"
    echo
    hr
  fi

  cat <<MENU

  $(bold "New session:")
  $(cyan 1)  Global Sentinel
  $(cyan 2)  Voice Agents Ops
  $(cyan 3)  OpenClaw Prod
  $(cyan 4)  GS Azure Quantum
  $(cyan 5)  Orchestrator
  $(cyan 6)  Dev Workspace
  $(cyan 7)  Plain shell
  $(cyan s)  Status / system info

  $(dim "q  quit / drop to bash")

MENU
  hr
  read -rp "  > " proj_choice

  case "$proj_choice" in
    r|R)
      if [ "$sc" -eq 0 ]; then
        yellow "  no active sessions"; echo; sleep 0.6
      elif [ "$sc" -eq 1 ]; then
        attach_named_session "$(session_names | sed -n '1p')"
      else
        echo
        bold "  Pick session:"; echo
        session_names | nl -w2 -s') '
        echo
        read -rp "  session name or #: " pick
        if [ -n "$pick" ]; then
          target=$(resolve_session_pick "$pick" || true)
          if [ -n "$target" ]; then
            attach_named_session "$target"
          else
            red "  session not found"; echo; sleep 0.6
          fi
        fi
      fi
      continue
      ;;
    k|K)
      if [ "$sc" -eq 0 ]; then
        yellow "  no active sessions"; echo; sleep 0.6
      else
        echo
        bold "  Kill session:"; echo
        session_names | nl -w2 -s') '
        echo
        read -rp "  session name or #: " pick
        target=$(resolve_session_pick "$pick" || true)
        if [ -n "$target" ]; then
          if [ -x "$SESSIONS_TOOL" ]; then
            "$SESSIONS_TOOL" kill "$target"
          else
            tmux kill-session -t "$target"
          fi
          sleep 0.7
        else
          red "  session not found"; echo; sleep 0.6
        fi
      fi
      continue
      ;;
    x|X)
      if [ "$sc" -eq 0 ]; then
        yellow "  no active sessions"; echo; sleep 0.6
      elif [ -x "$SESSIONS_TOOL" ]; then
        "$SESSIONS_TOOL" cleanup
        read -rp "  press enter "
      else
        yellow "  missing session tool"; echo; sleep 0.6
      fi
      continue
      ;;
    [1-6])
      proj=$(proj_name "$proj_choice")
      ;;
    7)
      cd "$HOME/projects" && exec bash -l
      ;;
    s|S)
      status_page; continue
      ;;
    q|Q|'')
      echo; exec bash -l
      ;;
    *)
      yellow "  unknown"; echo; sleep 0.4; continue
      ;;
  esac

  # Model sub-menu
  while :; do
    clear 2>/dev/null || true
    echo
    bold "  ⎈ $proj · select model"; echo
    hr
    cat <<MENU

  $(bold "── OpenAI ──")
  $(cyan 1)  gpt-5.4            $(dim "xhigh — hard bugs, planning")
  $(cyan 2)  gpt-5.2            $(dim "high  — general coding")
  $(cyan 3)  gpt-5.2-codex      $(dim "high  — code completions")
  $(cyan 4)  gpt-5.1-codex-mini $(dim "med   — quick edits")
  $(cyan 5)  gpt-5-mini         $(dim "med   — fast, cheap")
  $(cyan 6)  gpt-4o             $(dim "med   — multimodal")

  $(bold "── Claude ──")
  $(cyan 7)  claude-opus-4-6    $(dim "high  — complex reasoning")
  $(cyan 8)  claude-sonnet-4-6  $(dim "med   — balanced")
  $(cyan 9)  claude-haiku-4-5   $(dim "med   — fast Q&A")

  $(bold "── Other ──")
  $(cyan c)  Claude Code CLI    $(dim "      — native claude")

  $(dim "b  back")

MENU
    hr
    read -rp "  > " model_choice

    case "$model_choice" in
      [1-9])
        if [ "$model_choice" -le 6 ] && ! foundry_key_ready; then
          show_openai_profile_warning
          continue
        fi
        if launch_choice "$proj" "$model_choice"; then
          continue
        fi
        local_profile=$(profile_for "$model_choice")
        label=$(model_label "$model_choice")
        short=$(proj_short "$proj")
        session_name="${short}-${label}"
        if [ -n "$local_profile" ]; then
          launch_tmux "$proj" "$local_profile" "$session_name"
        fi
        ;;
      c|C)
        if launch_choice "$proj" "$model_choice"; then
          continue
        fi
        short=$(proj_short "$proj")
        session_name="${short}-claude"
        launch_tmux "$proj" "claude" "$session_name"
        ;;
      b|B|'')
        break
        ;;
      *)
        yellow "  unknown"; echo; sleep 0.4
        ;;
    esac
  done
done
