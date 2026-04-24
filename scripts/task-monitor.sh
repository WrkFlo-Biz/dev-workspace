#!/usr/bin/env bash
# task-monitor.sh — autonomous worker monitor + task dispatcher
# Runs in its own tmux session, checks all workers every 2 min,
# dispatches tasks to idle ones, replaces dead ones.
# Auto-completes tasks when workers go idle after being in_progress.
# Auto-refills queue from phase templates when pending runs low.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGFILE="/var/log/dws/monitor.log"
TASK_QUEUE="/home/moses/projects/dev-workspace/.state/task-queue.json"
INTERVAL=30
SYNC_STATUS_SCRIPT="${DWS_SYNC_STATUS_SCRIPT:-${SCRIPT_DIR}/sync-status.py}"

# Workers are generic — repo comes from the task queue, not hardcoded mapping.
# Default repo used when auto-refilling or when a task has no repo field.
DEFAULT_REPO="dev-workspace"

WORKERS=(worker-c worker-d worker-f worker-h)

declare -A LAST_TIMER
declare -A LAST_STATUS
declare -A RATE_LIMIT_HITS
declare -A RATE_LIMIT_STREAK
declare -A RATE_LIMIT_BACKOFF_UNTIL
declare -A RATE_LIMIT_PAUSE_UNTIL
declare -A RATE_LIMIT_RECOVERY_PENDING

# Global rate-aware dispatch state
GLOBAL_RATE_LIMIT_COUNT=0
GLOBAL_RATE_LIMIT_WINDOW_START=0
GLOBAL_DISPATCH_STAGGER=3
GLOBAL_THROTTLE_ACTIVE=0
GLOBAL_THROTTLE_UNTIL=0
DISPATCH_PAUSE_FLAG="${DWS_DISPATCH_PAUSE_FLAG:-/tmp/dws-dispatch-paused}"
DISPATCH_PAUSE_STATE=0

log() { printf "%s [monitor] %s\n" "$(date "+%H:%M:%S")" "$*" >> "$LOGFILE"; }

now_epoch() { date +%s; }

format_until() {
  local epoch="$1"
  date -d "@$epoch" "+%H:%M:%S" 2>/dev/null || printf '%s' "$epoch"
}

log_rate_limit() {
  local session="$1"
  shift
  log "RATE-LIMIT $session: $*"
}

rate_limit_backoff_seconds() {
  local streak="$1"
  case "$streak" in
    1) printf '30\n' ;;
    2) printf '60\n' ;;
    *) printf '120\n' ;;
  esac
}

clear_rate_limit_recovery() {
  local session="$1"
  RATE_LIMIT_STREAK[$session]=0
  RATE_LIMIT_BACKOFF_UNTIL[$session]=0
  RATE_LIMIT_PAUSE_UNTIL[$session]=0
  RATE_LIMIT_RECOVERY_PENDING[$session]=0
}

classify_worker() {
  local session="$1"
  local output
  output=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -15 || true)
  [ -z "$output" ] && { echo "DEAD"; return; }
  echo "$output" | grep -qE 'compact task|high demand' && { echo "COMPACTED"; return; }
  echo "$output" | grep -qE 'Conversation interrupted|Session ended' && { echo "CRASHED"; return; }
  echo "$output" | grep -qE 'rate limit|Rate limit|429' && { echo "RATELIMIT"; return; }
  echo "$output" | grep -qE 'Working \([0-9]' && { echo "WORKING"; return; }
  echo "$output" | grep -qE '^  gpt-|^›' && { echo "IDLE"; return; }
  echo "UNKNOWN"
}

get_next_task() {
  local repo="$1"
  python3 -c "
import json
with open('$TASK_QUEUE') as f:
    data = json.load(f)
for t in sorted(data['tasks'], key=lambda x: x['phase']):
    if t['status'] == 'pending':
        print(t['id'] + '|||' + t['repo'] + '|||' + t['description'])
        break
" 2>/dev/null
}

get_assigned_task() {
  local session="$1"
  python3 -c "
import json
with open('$TASK_QUEUE') as f:
    data = json.load(f)
for t in data['tasks']:
    if t.get('assigned') == '$session' and t['status'] == 'in_progress':
        repo = t.get('repo') or '$DEFAULT_REPO'
        print(t['id'] + '|||' + repo + '|||' + t['description'])
        break
" 2>/dev/null
}

mark_assigned() {
  local task_id="$1" session="$2"
  python3 -c "
import json
with open('$TASK_QUEUE') as f: data = json.load(f)
for t in data['tasks']:
    if t['id'] == '$task_id':
        t['assigned'] = '$session'
        t['status'] = 'in_progress'
        break
with open('$TASK_QUEUE', 'w') as f: json.dump(data, f, indent=2)
" 2>/dev/null
}

# Mark all in_progress tasks for a worker as completed
mark_completed() {
  local session="$1"
  python3 -c "
import json
with open('$TASK_QUEUE') as f: data = json.load(f)
changed = False
for t in data['tasks']:
    if t.get('assigned') == '$session' and t['status'] == 'in_progress':
        t['status'] = 'completed'
        changed = True
if changed:
    with open('$TASK_QUEUE', 'w') as f: json.dump(data, f, indent=2)
    print('completed')
" 2>/dev/null
}


# Compact a session to free context between tasks
compact_session() {
  local session="$1"
  log "$session: compacting context..."
  tmux send-keys -t "$session" '/compact' Enter
  sleep 8
  local check
  check=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -5)
  if echo "$check" | grep -qE 'gpt-|›'; then
    log "$session: compact done"
  else
    log "$session: compact may still be running, proceeding"
  fi
}

# Count pending tasks
count_pending() {
  python3 -c "
import json
with open('$TASK_QUEUE') as f: data = json.load(f)
print(sum(1 for t in data['tasks'] if t['status'] == 'pending'))
" 2>/dev/null
}

# Auto-refill queue when pending < 3
refill_queue() {
  local pending
  pending=$(count_pending || true)
  if [ -z "${pending:-}" ]; then
    log "queue low check failed"
    return 0
  fi
  if [ "${pending:-0}" -lt 3 ]; then
    log "queue low ($pending pending), auto-refilling..."
    python3 << 'REFILL_PY'
import json, random, string

with open("/home/moses/projects/dev-workspace/.state/task-queue.json") as f:
    data = json.load(f)

existing_ids = {t["id"] for t in data["tasks"]}

templates = []

added = 0
for t in templates:
    tid = "refill-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    if tid not in existing_ids:
        data["tasks"].append({"id": tid, "phase": t["phase"], "repo": t["repo"], "description": t["description"], "assigned": None, "status": "pending"})
        added += 1

with open("/home/moses/projects/dev-workspace/.state/task-queue.json", "w") as f:
    json.dump(data, f, indent=2)
print(f"refilled: added {added} tasks")
REFILL_PY
  fi
}

# Global rate-aware dispatch gate
should_dispatch() {
  local now
  now=$(now_epoch)

  # If global throttle is active, check if it expired
  if [ "$GLOBAL_THROTTLE_ACTIVE" -eq 1 ]; then
    if [ "$now" -ge "$GLOBAL_THROTTLE_UNTIL" ]; then
      GLOBAL_THROTTLE_ACTIVE=0
      GLOBAL_RATE_LIMIT_COUNT=0
      GLOBAL_RATE_LIMIT_WINDOW_START=$now
      log "global throttle expired, resuming normal dispatch"
    else
      local remaining=$((GLOBAL_THROTTLE_UNTIL - now))
      log "global throttle active, ${remaining}s remaining — skipping dispatch"
      return 1
    fi
  fi

  # Reset window every 5 minutes
  local window_age=$((now - GLOBAL_RATE_LIMIT_WINDOW_START))
  if [ "$window_age" -gt 300 ]; then
    GLOBAL_RATE_LIMIT_COUNT=0
    GLOBAL_RATE_LIMIT_WINDOW_START=$now
  fi

  # If 3+ workers hit rate limits in same window, throttle all dispatch for 120s
  if [ "$GLOBAL_RATE_LIMIT_COUNT" -ge 3 ]; then
    GLOBAL_THROTTLE_ACTIVE=1
    GLOBAL_THROTTLE_UNTIL=$((now + 120))
    log "global rate limit threshold reached ($GLOBAL_RATE_LIMIT_COUNT hits in window) — throttling all dispatch for 120s"
    return 1
  fi

  return 0
}

record_global_rate_limit() {
  local now
  now=$(now_epoch)
  GLOBAL_RATE_LIMIT_COUNT=$((GLOBAL_RATE_LIMIT_COUNT + 1))
  if [ "$GLOBAL_RATE_LIMIT_WINDOW_START" -eq 0 ]; then
    GLOBAL_RATE_LIMIT_WINDOW_START=$now
  fi
  log "global rate limit count: $GLOBAL_RATE_LIMIT_COUNT in current window"
}

dispatch_paused() {
  if [ -f "$DISPATCH_PAUSE_FLAG" ]; then
    if [ "$DISPATCH_PAUSE_STATE" -eq 0 ]; then
      log "dispatch pause active via ${DISPATCH_PAUSE_FLAG}; skipping new task dispatch"
    fi
    DISPATCH_PAUSE_STATE=1
    return 0
  fi

  if [ "$DISPATCH_PAUSE_STATE" -eq 1 ]; then
    log "dispatch pause cleared; resuming new task dispatch"
  fi
  DISPATCH_PAUSE_STATE=0
  return 1
}

dispatch_task() {
  local session="$1" task_repo="$2" task_text="$3"
  # Validate repo exists
  if [ ! -d "$HOME/projects/$task_repo" ]; then
    log "$session: repo $task_repo not found, using $DEFAULT_REPO"
    task_repo="$DEFAULT_REPO"
  fi
  log "dispatching to $session (repo=$task_repo): ${task_text:0:80}..."
  tmux send-keys -t "$session" "cd ~/projects/$task_repo && $task_text" Enter
  sleep 3
  tmux send-keys -t "$session" Enter
  sleep 5
  local check
  check=$(tmux capture-pane -t "$session" -p 2>/dev/null | grep -c "Working" || true)
  check=${check:-0}
  if [ "$check" -gt 0 ]; then
    log "$session: confirmed Working"
    return 0
  else
    log "$session: WARNING — not Working, retrying Enter"
    tmux send-keys -t "$session" Enter
    sleep 3
    check=$(tmux capture-pane -t "$session" -p 2>/dev/null | grep -c "Working" || true)
    check=${check:-0}
    if [ "$check" -gt 0 ]; then
      log "$session: confirmed Working on retry"
      return 0
    fi
    log "$session: FAILED to start"
    return 1
  fi
}

handle_rate_limit() {
  local session="$1" now hits streak delay retry_at pause_until remaining

  now=$(now_epoch)
  if [ "${LAST_STATUS[$session]:-}" = "RATELIMIT" ]; then
    pause_until=${RATE_LIMIT_PAUSE_UNTIL[$session]:-0}
    if [ "$pause_until" -gt "$now" ]; then
      remaining=$((pause_until - now))
      log_rate_limit "$session" "pause active, ${remaining}s remaining (hits=${RATE_LIMIT_HITS[$session]:-0}, streak=${RATE_LIMIT_STREAK[$session]:-0})"
    else
      remaining=$(( ${RATE_LIMIT_BACKOFF_UNTIL[$session]:-0} - now ))
      [ "$remaining" -lt 0 ] && remaining=0
      log_rate_limit "$session" "backoff active, ${remaining}s remaining (hits=${RATE_LIMIT_HITS[$session]:-0}, streak=${RATE_LIMIT_STREAK[$session]:-0})"
    fi
    return 0
  fi

  hits=$(( ${RATE_LIMIT_HITS[$session]:-0} + 1 ))
  streak=$(( ${RATE_LIMIT_STREAK[$session]:-0} + 1 ))
  delay=$(rate_limit_backoff_seconds "$streak")
  retry_at=$((now + delay))

  RATE_LIMIT_HITS[$session]=$hits
  RATE_LIMIT_STREAK[$session]=$streak
  RATE_LIMIT_BACKOFF_UNTIL[$session]=$retry_at
  RATE_LIMIT_RECOVERY_PENDING[$session]=1

  if [ "$streak" -ge 3 ]; then
    pause_until=$((now + 300))
    RATE_LIMIT_PAUSE_UNTIL[$session]=$pause_until
    log_rate_limit "$session" "hit=$hits streak=$streak, backoff=${delay}s, pausing retries for 300s until $(format_until "$pause_until")"
  else
    RATE_LIMIT_PAUSE_UNTIL[$session]=0
    log_rate_limit "$session" "hit=$hits streak=$streak, backoff=${delay}s until $(format_until "$retry_at")"
  fi

  record_global_rate_limit
}

retry_rate_limited_task() {
  local session="$1" now pause_until backoff_until remaining result task_id task_repo task_desc

  now=$(now_epoch)
  pause_until=${RATE_LIMIT_PAUSE_UNTIL[$session]:-0}
  if [ "$pause_until" -gt "$now" ]; then
    remaining=$((pause_until - now))
    log_rate_limit "$session" "pause active, not redispatching for ${remaining}s"
    return 10
  fi

  backoff_until=${RATE_LIMIT_BACKOFF_UNTIL[$session]:-0}
  if [ "$backoff_until" -gt "$now" ]; then
    remaining=$((backoff_until - now))
    log_rate_limit "$session" "backoff active, retry deferred for ${remaining}s"
    return 10
  fi

  result=$(get_assigned_task "$session" || true)
  if [ -z "$result" ]; then
    log_rate_limit "$session" "recovery expired with no in-progress task; clearing throttle state"
    clear_rate_limit_recovery "$session"
    return 1
  fi

  task_id="${result%%|||*}"
  result="${result#*|||}"
  task_repo="${result%%|||*}"
  task_desc="${result#*|||}"

  log_rate_limit "$session" "retrying task $task_id after cooldown"
  if dispatch_task "$session" "$task_repo" "$task_desc"; then
    RATE_LIMIT_RECOVERY_PENDING[$session]=0
    RATE_LIMIT_BACKOFF_UNTIL[$session]=0
    RATE_LIMIT_PAUSE_UNTIL[$session]=0
    return 11
  fi

  RATE_LIMIT_BACKOFF_UNTIL[$session]=$((now + INTERVAL))
  log_rate_limit "$session" "retry for task $task_id did not enter Working; deferring another ${INTERVAL}s"
  return 10
}

relaunch_session() {
  local session="$1" repo="$DEFAULT_REPO"
  log "relaunching $session (repo: $repo)"
  tmux kill-session -t "$session" 2>/dev/null || true
  sleep 1
  tmux new-session -d -s "$session" \
    "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects/$repo; exec codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox\""
  sleep 8
  local check
  check=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -5 || true)
  if echo "$check" | grep -qE 'gpt-|›'; then
    log "$session: relaunched ok"
  else
    log "$session: relaunch may have failed"
  fi
}

check_stuck() {
  local session="$1"
  local timer
  timer=$(tmux capture-pane -t "$session" -p 2>/dev/null | grep -oE 'Working \([0-9]+m [0-9]+s' | tail -1 || true)
  if [ -n "$timer" ] && [ "${LAST_TIMER[$session]:-}" = "$timer" ]; then
    log "$session: STUCK — same timer '$timer' for 2 checks"
    return 0
  fi
  LAST_TIMER[$session]="$timer"
  return 1
}

assign_idle_worker() {
  local session="$1" repo="$DEFAULT_REPO"
  local result task_id task_repo task_desc retry_rc
  local completed

  completed=$(mark_completed "$session" || true)
  if [ "$completed" = "completed" ]; then
    log "$session: marked previous task completed"
  fi

  if dispatch_paused; then
    return 12
  fi

  if [ "${RATE_LIMIT_RECOVERY_PENDING[$session]:-0}" -eq 1 ]; then
    if retry_rate_limited_task "$session"; then
      retry_rc=0
    else
      retry_rc=$?
    fi
    case "$retry_rc" in
      10|11) return "$retry_rc" ;;
    esac
  else
    clear_rate_limit_recovery "$session"
  fi

  # Check global rate limit before dispatching
  if ! should_dispatch; then
    log "$session: dispatch deferred by global throttle"
    return 10
  fi

  # Try preferred repo first
  result=$(get_next_task "$repo" || true)
  if [ -z "$result" ]; then
    for try_repo in dev-workspace wrkflo-orchestrator global-sentinel; do
      result=$(get_next_task "$try_repo" || true)
      [ -n "$result" ] && break
    done
  fi

  if [ -n "$result" ]; then
    task_id="${result%%|||*}"
    result="${result#*|||}"
    task_repo="${result%%|||*}"
    task_desc="${result#*|||}"
    if dispatch_task "$session" "$task_repo" "$task_desc"; then
      mark_assigned "$task_id" "$session"
    else
      log "$session: dispatch failed for task $task_id; leaving task pending"
    fi
  else
    log "$session: no tasks available"
  fi

  return 0
}

# ── Main loop ──

log "=== Monitor v2 started, ${#WORKERS[@]} workers, ${INTERVAL}s interval ==="

while true; do
  log "--- check cycle $(date '+%H:%M:%S') ---"

  # Auto-refill queue if running low
  refill_queue || log "queue refill check failed"
  dispatch_paused || true

  for session in "${WORKERS[@]}"; do
    status=$(classify_worker "$session")

    case "$status" in
      WORKING)
        if [ "${RATE_LIMIT_STREAK[$session]:-0}" -gt 0 ] || [ "${RATE_LIMIT_RECOVERY_PENDING[$session]:-0}" -eq 1 ]; then
          log_rate_limit "$session" "recovered and working; clearing throttle state"
          clear_rate_limit_recovery "$session"
        fi
        if check_stuck "$session"; then
          assign_rc=0
          relaunch_session "$session"
          if assign_idle_worker "$session"; then
            assign_rc=0
          else
            assign_rc=$?
          fi
          case "$assign_rc" in
            10) LAST_STATUS[$session]="BACKOFF" ;;
            11) LAST_STATUS[$session]="RETRYING" ;;
            12) LAST_STATUS[$session]="PAUSED" ;;
            *) LAST_STATUS[$session]="RELAUNCHED" ;;
          esac
        else
          log "$session: working (ok)"
          LAST_STATUS[$session]="WORKING"
        fi
        ;;
      IDLE)
        log "$session: idle"
        if assign_idle_worker "$session"; then
          assign_rc=0
        else
          assign_rc=$?
        fi
        case "$assign_rc" in
          10) LAST_STATUS[$session]="BACKOFF" ;;
          11) LAST_STATUS[$session]="RETRYING" ;;
          12) LAST_STATUS[$session]="PAUSED" ;;
          *) LAST_STATUS[$session]="IDLE" ;;
        esac
        sleep "$GLOBAL_DISPATCH_STAGGER"
        ;;
      COMPACTED|CRASHED)
        log "$session: $status — relaunching"
        relaunch_session "$session"
        if assign_idle_worker "$session"; then
          assign_rc=0
        else
          assign_rc=$?
        fi
        case "$assign_rc" in
          10) LAST_STATUS[$session]="BACKOFF" ;;
          11) LAST_STATUS[$session]="RETRYING" ;;
          12) LAST_STATUS[$session]="PAUSED" ;;
          *) LAST_STATUS[$session]="RELAUNCHED" ;;
        esac
        ;;
      RATELIMIT)
        handle_rate_limit "$session"
        LAST_STATUS[$session]="RATELIMIT"
        ;;
      DEAD)
        log "$session: dead — relaunching"
        relaunch_session "$session"
        LAST_STATUS[$session]="RELAUNCHED"
        ;;
      *)
        log "$session: unknown state"
        LAST_STATUS[$session]="UNKNOWN"
        ;;
    esac
  done

  # Orchestrator health check — restart immediately if down
  if tmux has-session -t orchestrator 2>/dev/null; then
    orch_status=$(classify_worker orchestrator)
    case "$orch_status" in
      WORKING)
        log "orchestrator: working (ok)"
        ;;
      IDLE)
        log "orchestrator: idle"
        ;;
      COMPACTED|CRASHED)
        log "orchestrator: $orch_status — relaunching immediately"
        tmux kill-session -t orchestrator 2>/dev/null || true
        sleep 1
        tmux new-session -d -s orchestrator "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects/wrkflo-orchestrator; exec codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox\""
        sleep 8
        log "orchestrator: relaunched"
        ;;
      DEAD)
        log "orchestrator: dead — relaunching immediately"
        tmux new-session -d -s orchestrator "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects/wrkflo-orchestrator; exec codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox\""
        sleep 8
        log "orchestrator: relaunched"
        ;;
      *)
        log "orchestrator: state=$orch_status"
        ;;
    esac
  else
    log "orchestrator: session missing — creating"
    tmux new-session -d -s orchestrator "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects/wrkflo-orchestrator; exec codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox\""
    sleep 8
    log "orchestrator: created"
  fi

  # Summary
  working=0
  for s in "${WORKERS[@]}"; do
    [ "${LAST_STATUS[$s]:-}" = "WORKING" ] && working=$((working+1))
  done
  pending=$(count_pending || true)
  pending=${pending:-unknown}
  log "--- cycle done: $working working, $pending pending tasks ---"
  python3 "$SYNC_STATUS_SCRIPT" >> "$LOGFILE" 2>&1 || log "sync-status refresh failed"
  sleep "$INTERVAL"
done
