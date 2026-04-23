#!/usr/bin/env bash
set -u
BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATUS_TOOL="${DWS_STATUS_TOOL:-$HOME/projects/dev-workspace/bin/dws-status.sh}"
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-/tmp/task-queue.json}"
HEALTH_LOG_PATH="${DWS_HEALTH_LOG_PATH:-/tmp/dws-health.log}"
# shellcheck source=/dev/null
. "$BASE_DIR/dws-env.sh"

have() {
  command -v "$1" >/dev/null 2>&1
}

to_epoch() {
  local raw_ts=${1:-}
  [ -n "$raw_ts" ] || return 1

  if have date; then
    date -d "$raw_ts" '+%s' 2>/dev/null && return 0
  fi

  if have python3; then
    python3 - "$raw_ts" <<'PY'
import sys
from datetime import datetime

raw = sys.argv[1]
try:
    print(int(datetime.strptime(raw, "%Y-%m-%d %H:%M:%S").timestamp()))
except Exception:
    raise SystemExit(1)
PY
    return $?
  fi

  return 1
}

age_summary() {
  local raw_ts=${1:-} ts_epoch now delta
  ts_epoch=$(to_epoch "$raw_ts") || return 1
  now=$(date '+%s' 2>/dev/null || printf '0')
  [ "$now" -ge "$ts_epoch" ] || return 1
  delta=$((now - ts_epoch))

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

warn_pct() {
  local n=${1:-0}
  if [ "$n" -ge 90 ]; then red "${n}%"; elif [ "$n" -ge 80 ]; then yellow "${n}%"; else green "${n}%"; fi
}

mem_pct() {
  if have free; then
    free | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}'
  elif [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/ { total=$2 }
      /^MemAvailable:/ { avail=$2 }
      END {
        if (total > 0) {
          printf "%.0f", ((total-avail)/total)*100
        } else {
          printf "0"
        }
      }
    ' /proc/meminfo
  else
    printf '0'
  fi
}

mem_human() {
  if have free; then
    free -h | awk '/^Mem:/ {print $3 "/" $2}'
  elif [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/ { total=$2 }
      /^MemAvailable:/ { avail=$2 }
      END {
        used=(total-avail)/1024/1024
        total_gib=total/1024/1024
        printf "%.1fGi/%.1fGi", used, total_gib
      }
    ' /proc/meminfo
  else
    printf 'unknown'
  fi
}

tmux_summary() {
  local rows session_count attached_count detached_count

  if ! have tmux; then
    printf '%s\n' "$(red 'tmux missing')"
    return
  fi

  rows=$(tmux list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null || true)
  if [ -z "$rows" ]; then
    printf '%s\n' "$(dim '0 total')"
    return
  fi

  session_count=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  attached_count=$(printf '%s\n' "$rows" | awk -F'|' '$2 != "0" {count++} END {print count+0}')
  detached_count=$((session_count - attached_count))

  printf '%s active (%s attached, %s detached)\n' "$session_count" "$attached_count" "$detached_count"
}

last_health_summary() {
  local latest ts counts ok_count fail_count status_label age_label

  [ -s "$HEALTH_LOG_PATH" ] || {
    printf '%s\n' "$(yellow 'unavailable')"
    return
  }

  latest=$(tail -n 1 "$HEALTH_LOG_PATH" 2>/dev/null || true)
  [ -n "$latest" ] || {
    printf '%s\n' "$(yellow 'unavailable')"
    return
  }

  ts=${latest%% health:*}
  counts=${latest#*health: }
  ok_count=$(printf '%s\n' "$counts" | awk -F'[ ,]+' '{print $1}')
  fail_count=$(printf '%s\n' "$counts" | awk -F'[ ,]+' '{print $3}')

  case "$fail_count" in
    ''|*[!0-9]*)
      printf '%s\n' "$latest"
      return
      ;;
    0) status_label=$(green 'ok') ;;
    *) status_label=$(red 'fail') ;;
  esac

  age_label=$(age_summary "$ts" || true)

  if [ -n "$age_label" ]; then
    printf '%s  %s ok / %s fail  %s\n' "$status_label" "${ok_count:-?}" "$fail_count" "$(dim "${ts} (${age_label})")"
  else
    printf '%s  %s ok / %s fail  %s\n' "$status_label" "${ok_count:-?}" "$fail_count" "$(dim "$ts")"
  fi
}

task_queue_summary() {
  [ -s "$TASK_QUEUE_PATH" ] || {
    printf '%s\n' "$(dim 'unavailable')"
    return
  }

  if ! have python3; then
    printf '%s\n' "$(yellow 'python3 missing')"
    return
  fi

  python3 - "$TASK_QUEUE_PATH" <<'PY'
import json
import sys
from collections import Counter

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"invalid ({exc.__class__.__name__})")
    raise SystemExit(0)

tasks = data.get("tasks") or []
status_counts = Counter((task.get("status") or "unknown") for task in tasks)
unassigned = sum(1 for task in tasks if not task.get("assigned"))
last_reconciled = data.get("last_reconciled_at")

parts = [f"{len(tasks)} tasks"]
active = status_counts.get("in_progress", 0)
pending = status_counts.get("pending", 0)
completed = status_counts.get("completed", 0)
failed = status_counts.get("failed", 0)
unknown = status_counts.get("unknown", 0)

parts.append(f"{active} active")
if pending:
    parts.append(f"{pending} pending")
if completed:
    parts.append(f"{completed} done")
if failed:
    parts.append(f"{failed} failed")
if unknown:
    parts.append(f"{unknown} unknown")
if unassigned:
    parts.append(f"{unassigned} unassigned")
if last_reconciled:
    parts.append(f"reconciled {last_reconciled}")
print(", ".join(parts))
PY
}

disk_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5+0}')
disk_human=$(df -Ph / | awk 'NR==2 {print $3 "/" $2}')
memory_pct=$(mem_pct)
memory_human=$(mem_human)

printf '%s %s\n' "$(bold 'Dev Workspace')" "$(dim "$(date '+%Y-%m-%d %H:%M:%S %Z')")"
printf '  host: %s  vm: %s  mac: %s\n' "$(green "$(hostname -s 2>/dev/null || hostname)")" "100.117.16.63" "${MAC_GUI_URL#http://}"

echo
printf '%s\n' "$(bold 'Workspace snapshot')"
printf '  tmux:   %s\n' "$(tmux_summary)"
printf '  health: %s\n' "$(last_health_summary)"
printf '  usage:  disk / %s %s  mem %s %s\n' \
  "$(warn_pct "$disk_pct")" "$(dim "(${disk_human})")" \
  "$(warn_pct "$memory_pct")" "$(dim "(${memory_human})")"
printf '  queue:  %s\n' "$(task_queue_summary)"

echo
printf '%s\n' "$(bold 'Orchestrator')"
if [ -x "$STATUS_TOOL" ]; then
  "$STATUS_TOOL" --motd 2>/dev/null || true
else
  "$BASE_DIR/dws-launcher.sh" status --motd 2>/dev/null || true
fi

echo
printf '%s\n' "$(bold 'Active tmux sessions')"
if tmux ls >/dev/null 2>&1; then
  tmux ls -F '  #{session_name}  #{?session_attached,attached,detached}  #{session_windows}w'
else
  printf '  %s\n' "$(dim 'none')"
fi

echo
printf '%s\n' "$(bold 'Health alerts')"
if [ -s /tmp/dws-health-alerts.log ]; then
  tail -5 /tmp/dws-health-alerts.log | sed 's/^/  /'
else
  printf '  %s\n' "$(green 'none')"
fi
