#!/usr/bin/env bash
set -u

TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-/tmp/task-queue.json}"
BACKUP_ROOT="${DWS_BACKUP_ROOT:-$HOME/backups/dev-workspace}"
TAILSCALE_TIMEOUT_SECONDS="${DWS_TAILSCALE_TIMEOUT_SECONDS:-1}"

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

dim() {
  paint '2' "$1"
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

run_quick() {
  local seconds="${1:-0}"
  shift || true

  if have timeout && is_int "$seconds" && [ "$seconds" -gt 0 ]; then
    timeout "${seconds}s" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

now_epoch() {
  if is_int "${DWS_MOTD_NOW_EPOCH:-}"; then
    printf '%s\n' "$DWS_MOTD_NOW_EPOCH"
  else
    date '+%s' 2>/dev/null || printf '0\n'
  fi
}

format_now() {
  if [ -n "${DWS_MOTD_NOW_LABEL:-}" ]; then
    printf '%s\n' "$DWS_MOTD_NOW_LABEL"
  else
    date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unknown time\n'
  fi
}

to_epoch() {
  local raw_ts="${1:-}"

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
    print(int(datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()))
except Exception:
    raise SystemExit(1)
PY
    return $?
  fi

  return 1
}

format_epoch_utc() {
  local epoch="${1:-}"

  is_int "$epoch" || return 1

  date -u -d "@${epoch}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null && return 0
  date -u -r "$epoch" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null && return 0
  printf 'epoch %s\n' "$epoch"
}

age_from_epoch() {
  local epoch="${1:-}" now delta

  is_int "$epoch" || return 1
  now=$(now_epoch)
  is_int "$now" || return 1
  [ "$now" -ge "$epoch" ] || return 1
  delta=$((now - epoch))

  if [ "$delta" -lt 60 ]; then
    printf '%ss ago\n' "$delta"
  elif [ "$delta" -lt 3600 ]; then
    printf '%sm ago\n' $((delta / 60))
  elif [ "$delta" -lt 86400 ]; then
    printf '%sh ago\n' $((delta / 3600))
  else
    printf '%sd ago\n' $((delta / 86400))
  fi
}

file_mtime_epoch() {
  local path="${1:-}"

  [ -n "$path" ] || return 1

  stat -c '%Y' "$path" 2>/dev/null && return 0
  stat -f '%m' "$path" 2>/dev/null && return 0
  return 1
}

disk_percent() {
  df -Pk / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 + 0 }'
}

disk_human() {
  df -Ph / 2>/dev/null | awk 'NR == 2 { print $3 "/" $2 }'
}

mem_percent() {
  if have free; then
    free 2>/dev/null | awk '/^Mem:/ { printf "%.0f", ($3 / $2) * 100 }'
    return 0
  fi

  if [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/ { total = $2 }
      /^MemAvailable:/ { available = $2 }
      END {
        if (total > 0) {
          printf "%.0f", ((total - available) / total) * 100
        }
      }
    ' /proc/meminfo
    return 0
  fi

  return 1
}

mem_human() {
  if have free; then
    free -h 2>/dev/null | awk '/^Mem:/ { print $3 "/" $2 }'
    return 0
  fi

  if [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/ { total = $2 }
      /^MemAvailable:/ { available = $2 }
      END {
        if (total > 0) {
          used = (total - available) / 1024 / 1024
          gib = total / 1024 / 1024
          printf "%.1fGi/%.1fGi", used, gib
        }
      }
    ' /proc/meminfo
    return 0
  fi

  return 1
}

uptime_summary() {
  uptime -p 2>/dev/null || uptime 2>/dev/null || printf 'unavailable\n'
}

json_count_tailscale_clients() {
  jq -r '
    [((.Peer // {}) | to_entries[]?.value) | select(.Online == true)] | length
  ' 2>/dev/null
}

json_first_tailscale_ip() {
  jq -r '
    ((.Self.TailscaleIPs // [])
      | map(select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")))
      | .[0]) // ""
  ' 2>/dev/null
}

tailscale_peer_count_text() {
  local self_ip="${1:-}"

  run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale status --peers | awk -v self="$self_ip" '
    $1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && $1 != self && $5 != "-" {
      count++
    }
    END {
      print count + 0
    }
  '
}

tailscale_summary() {
  local payload="" ip="" clients=""

  if ! have tailscale; then
    printf 'unavailable\n'
    return
  fi

  if have jq; then
    payload=$(run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale status --json || true)
    if [ -n "$payload" ]; then
      ip=$(printf '%s\n' "$payload" | json_first_tailscale_ip || true)
      clients=$(printf '%s\n' "$payload" | json_count_tailscale_clients || true)
    fi
  fi

  if [ -z "$ip" ]; then
    ip=$(run_quick "$TAILSCALE_TIMEOUT_SECONDS" tailscale ip -4 | sed -n '1p' || true)
  fi

  if ! is_int "$clients"; then
    clients=$(tailscale_peer_count_text "$ip" || true)
  fi

  if ! is_int "$clients"; then
    clients=""
  fi

  if [ -n "$ip" ] && [ -n "$clients" ]; then
    printf '%s  %s clients online\n' "$ip" "$clients"
  elif [ -n "$ip" ]; then
    printf '%s\n' "$ip"
  else
    printf 'unavailable\n'
  fi
}

task_queue_counts() {
  if [ ! -e "$TASK_QUEUE_PATH" ]; then
    printf 'unavailable\n'
    return 1
  fi

  if [ ! -s "$TASK_QUEUE_PATH" ]; then
    printf 'empty\n'
    return 1
  fi

  if have jq; then
    jq -r '
      (.tasks // []) as $tasks |
      reduce $tasks[] as $task (
        {pending: 0, active: 0, done: 0, total: 0};
        .total += 1 |
        (($task.status // "") | ascii_downcase) as $status |
        if $status == "pending" then
          .pending += 1
        elif ($status == "in_progress" or $status == "active") then
          .active += 1
        elif ($status == "completed" or $status == "done") then
          .done += 1
        else
          .
        end
      ) |
      [.pending, .active, .done, .total] | @tsv
    ' "$TASK_QUEUE_PATH" 2>/dev/null && return 0

    printf 'invalid\n'
    return 1
  fi

  if have python3; then
    python3 - "$TASK_QUEUE_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    print("invalid")
    raise SystemExit(1)

pending = active = done = 0
tasks = data.get("tasks") or []
for task in tasks:
    status = str(task.get("status") or "").lower()
    if status == "pending":
        pending += 1
    elif status in {"in_progress", "active"}:
        active += 1
    elif status in {"completed", "done"}:
        done += 1

print(f"{pending}\t{active}\t{done}\t{len(tasks)}")
PY
    return $?
  fi

  printf 'unavailable\n'
  return 1
}

task_queue_summary() {
  local counts pending active done_count total

  counts=$(task_queue_counts) || {
    printf '%s\n' "$counts"
    return
  }

  IFS=$'\t' read -r pending active done_count total <<<"$counts"
  printf 'pending=%s  active=%s  done=%s  total=%s\n' \
    "$pending" "$active" "$done_count" "$total"
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

backup_summary() {
  local snapshot metadata_path created_at="" epoch="" stamp="" age=""

  snapshot=$(latest_snapshot || true)
  if [ -z "$snapshot" ]; then
    printf 'unavailable\n'
    return
  fi

  metadata_path="${snapshot}/meta/summary.txt"
  if [ ! -f "$metadata_path" ]; then
    metadata_path="$snapshot"
  fi

  if [ -f "$metadata_path" ]; then
    created_at=$(sed -n 's/^created_at=//p' "$metadata_path" | sed -n '1p')
  fi

  if [ -n "$created_at" ]; then
    epoch=$(to_epoch "$created_at" || true)
  else
    epoch=$(file_mtime_epoch "$metadata_path" || true)
  fi

  if is_int "$epoch"; then
    stamp=$(format_epoch_utc "$epoch" || true)
    age=$(age_from_epoch "$epoch" || true)
  fi

  if [ -z "$stamp" ] && [ -n "$created_at" ]; then
    stamp="$created_at"
  fi

  if [ -z "$stamp" ]; then
    printf '%s\n' "$snapshot"
    return
  fi

  if [ -n "$age" ]; then
    printf '%s (%s)\n' "$stamp" "$age"
  else
    printf '%s\n' "$stamp"
  fi
}

session_repo_from_name() {
  case "${1%%-*}" in
    gs) printf 'global-sentinel\n' ;;
    voice) printf 'wrkflo-voice-agents-ops\n' ;;
    oclaw) printf 'openclaw-prod\n' ;;
    gsaq) printf 'global-sentinel-azure-quantum\n' ;;
    orch) printf 'wrkflo-orchestrator\n' ;;
    dws) printf 'dev-workspace\n' ;;
    *) printf '\n' ;;
  esac
}

session_repo_name() {
  local session_name="${1:-}" project="${2:-}" path="${3:-}" top=""

  if [ -n "$project" ]; then
    printf '%s\n' "$project"
    return
  fi

  if [ -n "$path" ] && [ -d "$path" ]; then
    if have git; then
      top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
    fi
    if [ -n "$top" ]; then
      basename "$top"
      return
    fi
    case "$path" in
      "$HOME"/projects/*)
        printf '%s\n' "${path#"$HOME"/projects/}" | sed 's#/.*##'
        return
        ;;
    esac
  fi

  project=$(session_repo_from_name "$session_name")
  if [ -n "$project" ]; then
    printf '%s\n' "$project"
  else
    printf -- '-\n'
  fi
}

render_tmux_sessions() {
  local rows session_count name attached project path repo state

  if ! have tmux; then
    printf '%s (%s)\n' "$(bold 'Tmux Sessions')" "unavailable"
    return
  fi

  rows=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{@dws_project}|#{pane_current_path}' 2>/dev/null || true)
  session_count=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  printf '%s (%s)\n' "$(bold 'Tmux Sessions')" "${session_count:-0}"

  if [ -z "$rows" ]; then
    printf '  none\n'
    return
  fi

  while IFS='|' read -r name attached project path; do
    [ -n "$name" ] || continue
    repo=$(session_repo_name "$name" "$project" "$path")
    if [ "${attached:-0}" != "0" ]; then
      state="attached"
    else
      state="detached"
    fi
    printf '  %-16s %-28s %s\n' "$name" "$repo" "$state"
  done < <(printf '%s\n' "$rows" | sed '/^$/d' | sort -t'|' -k1,1)
}

disk_pct=$(disk_percent || true)
disk_used=$(disk_human || true)
memory_pct=$(mem_percent || true)
memory_used=$(mem_human || true)

printf '%s %s\n' "$(bold 'Dev Workspace')" "$(dim "$(format_now)")"
printf '  host:     %s\n' "$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
printf '  uptime:   %s\n' "$(uptime_summary)"
printf '  tailnet:  %s\n' "$(tailscale_summary)"
printf '  usage:    disk=%s (%s)  mem=%s%% (%s)\n' \
  "${disk_pct:-?}%" "${disk_used:-unknown}" "${memory_pct:-?}" "${memory_used:-unknown}"
printf '  queue:    %s\n' "$(task_queue_summary)"
printf '  backup:   %s\n' "$(backup_summary)"
printf '\n'
render_tmux_sessions
