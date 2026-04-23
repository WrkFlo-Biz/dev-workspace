#!/usr/bin/env bash
set -euo pipefail

SESSIONS=(dws-a dws-b worker-c worker-d worker-e worker-f worker-g)
LOG_FILE="/tmp/monitor-log.txt"
QUEUE_FILE="/tmp/task-queue.md"
STATE_FILE="/tmp/monitor-state.sh"
LOCK_FILE="/tmp/monitor-dispatcher.lock"
PID_FILE="/tmp/monitor-dispatcher.pid"
INTERVAL_SECONDS="${MONITOR_INTERVAL_SECONDS:-120}"

declare -A LAST_STATUS
declare -A LAST_TIMER
declare -A SAME_TIMER_COUNT
declare -A LAST_TASK_HASH
CLASSIFY_STATUS=""
CLASSIFY_TIMER=""
CLASSIFY_TAIL=""

log_line() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_FILE"
}

repo_for() {
  case "$1" in
    dws-a|worker-g) printf '%s\n' "dev-workspace" ;;
    dws-b|worker-c|worker-f) printf '%s\n' "wrkflo-orchestrator" ;;
    worker-d|worker-e) printf '%s\n' "global-sentinel" ;;
    *) return 1 ;;
  esac
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  for session in "${SESSIONS[@]}"; do
    : "${LAST_STATUS[$session]:=UNKNOWN}"
    : "${LAST_TIMER[$session]:=}"
    : "${SAME_TIMER_COUNT[$session]:=0}"
    : "${LAST_TASK_HASH[$session]:=}"
  done
}

save_state() {
  local tmp
  tmp=$(mktemp)
  {
    declare -p LAST_STATUS
    declare -p LAST_TIMER
    declare -p SAME_TIMER_COUNT
    declare -p LAST_TASK_HASH
  } >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

task_for_session() {
  local session
  session="$1"
  [[ -f "$QUEUE_FILE" ]] || return 0
  awk -v want="## '"$session"' — NEXT TASK" '
    $0 == want { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$QUEUE_FILE"
}

tail_text() {
  tmux capture-pane -t "$1" -p 2>&1 | tail -10
}

full_text() {
  tmux capture-pane -t "$1" -p 2>&1 || true
}

extract_timer() {
  local text timer
  text="$1"
  timer=$(grep -oE 'Working \([^)]*\)' <<<"$text" | tail -1 | sed -E 's/^Working \(([^)]*)\)$/\1/' || true)
  printf '%s\n' "$timer"
}

timer_over_45m() {
  local timer mins
  timer="$1"
  [[ -n "$timer" ]] || return 1
  mins=$(sed -nE 's/.*([0-9]+)m.*/\1/p' <<<"$timer" | tail -1)
  [[ -n "$mins" ]] && (( mins > 45 ))
}

classify_session() {
  local session tail timer
  session="$1"
  CLASSIFY_STATUS="UNKNOWN"
  CLASSIFY_TIMER=""
  CLASSIFY_TAIL=""
  if ! tmux has-session -t "$session" 2>/dev/null; then
    CLASSIFY_STATUS="DEAD"
    return 0
  fi

  tail=$(tail_text "$session")
  CLASSIFY_TAIL="$tail"

  if grep -Eiq 'compact error|rate limit|Conversation interrupted|Session ended' <<<"$tail"; then
    CLASSIFY_STATUS="DEAD"
    return 0
  fi

  if grep -q 'Working (' <<<"$tail"; then
    timer=$(extract_timer "$tail")
    CLASSIFY_TIMER="$timer"
    if timer_over_45m "$timer"; then
      CLASSIFY_STATUS="STUCK"
      return 0
    fi
    if [[ "${LAST_TIMER[$session]:-}" == "$timer" && -n "$timer" ]]; then
      SAME_TIMER_COUNT[$session]=$(( ${SAME_TIMER_COUNT[$session]:-0} + 1 ))
    else
      SAME_TIMER_COUNT[$session]=0
    fi
    LAST_TIMER[$session]="$timer"
    if (( ${SAME_TIMER_COUNT[$session]:-0} >= 1 )); then
      CLASSIFY_STATUS="STUCK"
    else
      CLASSIFY_STATUS="WORKING"
    fi
    return 0
  fi

  SAME_TIMER_COUNT[$session]=0
  LAST_TIMER[$session]=""
  if grep -q '›' <<<"$tail"; then
    CLASSIFY_STATUS="IDLE"
  else
    CLASSIFY_STATUS="UNKNOWN"
  fi
}

relaunch_session() {
  local session repo task
  session="$1"
  repo=$(repo_for "$session")
  task="$2"

  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects/$repo; exec codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox\""
  log_line "relaunch $session repo=$repo reason=dead"
  sleep 8

  if [[ -n "${task//[[:space:]]/}" ]]; then
    dispatch_task "$session" "$task" "redispatch"
  fi
}

dispatch_task() {
  local session task mode tail hash
  session="$1"
  task="$2"
  mode="${3:-dispatch}"
  [[ -n "${task//[[:space:]]/}" ]] || {
    log_line "$mode $session skipped empty-task"
    return 0
  }

  tmux send-keys -t "$session" Escape
  sleep 1
  tmux send-keys -t "$session" C-u "$task"
  tmux send-keys -t "$session" Enter
  sleep 3
  tmux send-keys -t "$session" Enter
  sleep 2

  tail=$(tail_text "$session")
  if ! grep -q 'Working (' <<<"$tail"; then
    tmux send-keys -t "$session" Enter
    sleep 2
    tail=$(tail_text "$session")
  fi

  hash=$(printf '%s' "$task" | sha1sum | awk '{print $1}')
  LAST_TASK_HASH[$session]="$hash"

  if grep -q 'Working (' <<<"$tail"; then
    log_line "$mode $session ok"
  else
    log_line "$mode $session no-working-indicator"
  fi
}

investigate_stuck() {
  local session
  session="$1"
  log_line "investigate $session stuck timer=${LAST_TIMER[$session]:-unknown}"
  full_text "$session" | tail -20 >>"$LOG_FILE"
}

monitor_cycle() {
  local session status tail task task_hash
  load_state
  touch "$LOG_FILE"

  for session in "${SESSIONS[@]}"; do
    classify_session "$session"
    status="$CLASSIFY_STATUS"
    tail="$CLASSIFY_TAIL"
    log_line "check $session status=$status tail=$(printf '%q' "$tail")"

    case "$status" in
      DEAD)
        task="$(task_for_session "$session")"
        relaunch_session "$session" "$task"
        ;;
      IDLE)
        task="$(task_for_session "$session")"
        task_hash=$(printf '%s' "$task" | sha1sum | awk '{print $1}')
        if [[ -n "${task//[[:space:]]/}" && "${LAST_TASK_HASH[$session]:-}" != "$task_hash" ]]; then
          dispatch_task "$session" "$task" "dispatch"
        else
          log_line "idle $session no-new-task"
        fi
        ;;
      STUCK)
        investigate_stuck "$session"
        ;;
      *)
        :
        ;;
    esac

    LAST_STATUS[$session]="$status"
  done

  save_state
}

main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 0
  printf '%s\n' "$$" >"$PID_FILE"

  if [[ "${1:-}" == "--once" ]]; then
    monitor_cycle
    exit 0
  fi

  while true; do
    monitor_cycle
    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
