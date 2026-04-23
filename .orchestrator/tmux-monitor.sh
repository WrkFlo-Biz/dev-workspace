#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/moses/dev-workspace"
STATUS_FILE="/tmp/orchestrator-status.txt"
STATE_FILE="/tmp/orchestrator-state.sh"
PID_FILE="/tmp/orchestrator-monitor.pid"
LOCK_FILE="/tmp/orchestrator-monitor.lock"
INTERVAL_SECONDS="${ORCHESTRATOR_INTERVAL_SECONDS:-120}"
DEFAULT_MANAGED_SESSIONS=(dws-a dws-b)
ORCHESTRATOR_SESSION_PREFIX="orchestrator"

TASK1_PATH="$WORKDIR/docs/troubleshooting.md"
TASK2_PATH="$WORKDIR/scripts/dws-cleanup.sh"
TASK1_PROMPT="Create docs/troubleshooting.md covering common issues and fixes for SSH drops, Foundry key missing, tmux session recovery, and Codex compaction errors. Work in $WORKDIR, avoid unrelated files, run any relevant checks, and summarize results."
TASK2_PROMPT="Create scripts/dws-cleanup.sh to clean up old tmux sessions, stale logs, and temp files. Work in $WORKDIR, make it safe and idempotent, run a basic smoke test, and summarize results."
TASK3_PROMPT="Test all scripts end-to-end in $WORKDIR, fix any bugs you find, run the relevant checks, and summarize results."

RUN_ONCE=0
if [[ "${1:-}" == "--once" ]]; then
  RUN_ONCE=1
fi

task_label() {
  case "$1" in
    task1) printf '%s\n' "docs/troubleshooting.md" ;;
    task2) printf '%s\n' "scripts/dws-cleanup.sh" ;;
    task3) printf '%s\n' "test all scripts" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

task_prompt() {
  case "$1" in
    task1) printf '%s\n' "$TASK1_PROMPT" ;;
    task2) printf '%s\n' "$TASK2_PROMPT" ;;
    task3) printf '%s\n' "$TASK3_PROMPT" ;;
    *) return 1 ;;
  esac
}

session_key() {
  printf '%s\n' "${1//[^A-Za-z0-9_]/_}"
}

array_contains() {
  local needle item
  needle="$1"
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

is_excluded_session() {
  [[ "$1" == "$ORCHESTRATOR_SESSION_PREFIX"* ]]
}

discover_managed_sessions() {
  local listing line session
  listing=$(tmux ls 2>/dev/null || true)
  [[ -z "$listing" ]] && return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    session="${line%%:*}"
    is_excluded_session "$session" && continue
    printf '%s\n' "$session"
  done <<<"$listing"
}

get_last_state() {
  local key
  key=$(session_key "$1")
  eval "printf '%s\n' \"\${SESSION_${key}_LAST_STATE:-unknown}\""
}

set_last_state() {
  local key
  key=$(session_key "$1")
  eval "SESSION_${key}_LAST_STATE=\$2"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  if ! declare -p KNOWN_SESSIONS >/dev/null 2>&1; then
    KNOWN_SESSIONS=()
  fi
  if ((${#KNOWN_SESSIONS[@]} == 0)); then
    mapfile -t KNOWN_SESSIONS < <(discover_managed_sessions)
  fi
  if ((${#KNOWN_SESSIONS[@]} == 0)); then
    KNOWN_SESSIONS=("${DEFAULT_MANAGED_SESSIONS[@]}")
  fi

  : "${TASK1_STATUS:=pending}"
  : "${TASK1_ASSIGNED_TO:=}"
  : "${TASK2_STATUS:=pending}"
  : "${TASK2_ASSIGNED_TO:=}"
  : "${TASK3_STATUS:=pending}"
  : "${TASK3_ASSIGNED_TO:=}"
  : "${TASK3_STARTED:=0}"

  for session in "${KNOWN_SESSIONS[@]}"; do
    set_last_state "$session" "$(get_last_state "$session")"
  done
}

save_state() {
  local tmp key value
  tmp=$(mktemp)
  {
    printf 'KNOWN_SESSIONS=('
    for session in "${KNOWN_SESSIONS[@]}"; do
      printf '%q ' "$session"
    done
    printf ')\n'
    printf 'TASK1_STATUS=%q\n' "$TASK1_STATUS"
    printf 'TASK1_ASSIGNED_TO=%q\n' "$TASK1_ASSIGNED_TO"
    printf 'TASK2_STATUS=%q\n' "$TASK2_STATUS"
    printf 'TASK2_ASSIGNED_TO=%q\n' "$TASK2_ASSIGNED_TO"
    printf 'TASK3_STATUS=%q\n' "$TASK3_STATUS"
    printf 'TASK3_ASSIGNED_TO=%q\n' "$TASK3_ASSIGNED_TO"
    printf 'TASK3_STARTED=%q\n' "$TASK3_STARTED"
    for session in "${KNOWN_SESSIONS[@]}"; do
      key=$(session_key "$session")
      eval "value=\${SESSION_${key}_LAST_STATE:-unknown}"
      printf 'SESSION_%s_LAST_STATE=%q\n' "$key" "$value"
    done
  } >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

classify_tail() {
  local tail
  tail="$1"
  if grep -q 'Working (' <<<"$tail"; then
    printf '%s\n' "busy"
  elif grep -q 'tab to queue message' <<<"$tail" || grep -q 'gpt-5' <<<"$tail"; then
    printf '%s\n' "idle"
  elif [[ -z "${tail//[[:space:]]/}" ]]; then
    printf '%s\n' "unknown"
  else
    printf '%s\n' "busy"
  fi
}

refresh_task_status_from_files() {
  if [[ -f "$TASK1_PATH" ]]; then
    TASK1_STATUS="completed"
  fi
  if [[ -f "$TASK2_PATH" ]]; then
    TASK2_STATUS="completed"
  fi
}

clear_assignments_for_session() {
  local session
  session="$1"

  if [[ "$TASK1_STATUS" != "completed" && "$TASK1_ASSIGNED_TO" == "$session" ]]; then
    TASK1_STATUS="pending"
    TASK1_ASSIGNED_TO=""
  fi
  if [[ "$TASK2_STATUS" != "completed" && "$TASK2_ASSIGNED_TO" == "$session" ]]; then
    TASK2_STATUS="pending"
    TASK2_ASSIGNED_TO=""
  fi
  if [[ "$TASK3_STATUS" != "completed" && "$TASK3_ASSIGNED_TO" == "$session" ]]; then
    TASK3_STATUS="pending"
    TASK3_ASSIGNED_TO=""
    TASK3_STARTED=0
  fi
}

launch_session() {
  local session
  session="$1"
  tmux new-session -d -s "$session" -c "$WORKDIR" "bash -lc 'cd \"$WORKDIR\" && codex'"
}

next_task_to_assign() {
  if [[ "$TASK1_STATUS" == "pending" && -z "$TASK1_ASSIGNED_TO" ]]; then
    printf '%s\n' "task1"
    return 0
  fi
  if [[ "$TASK2_STATUS" == "pending" && -z "$TASK2_ASSIGNED_TO" ]]; then
    printf '%s\n' "task2"
    return 0
  fi
  if [[ "$TASK1_STATUS" == "completed" && "$TASK2_STATUS" == "completed" && "$TASK3_STATUS" == "pending" && -z "$TASK3_ASSIGNED_TO" ]]; then
    printf '%s\n' "task3"
    return 0
  fi
  return 1
}

session_has_pending_assignment() {
  local session
  session="$1"
  [[ "$TASK1_STATUS" != "completed" && "$TASK1_ASSIGNED_TO" == "$session" ]] ||
  [[ "$TASK2_STATUS" != "completed" && "$TASK2_ASSIGNED_TO" == "$session" ]] ||
  [[ "$TASK3_STATUS" != "completed" && "$TASK3_ASSIGNED_TO" == "$session" ]]
}

assign_task() {
  local session task prompt
  session="$1"
  task="$2"
  prompt=$(task_prompt "$task")
  tmux send-keys -t "$session" C-u "$prompt" C-m

  case "$task" in
    task1)
      TASK1_STATUS="assigned"
      TASK1_ASSIGNED_TO="$session"
      ;;
    task2)
      TASK2_STATUS="assigned"
      TASK2_ASSIGNED_TO="$session"
      ;;
    task3)
      TASK3_STATUS="assigned"
      TASK3_ASSIGNED_TO="$session"
      TASK3_STARTED=0
      ;;
  esac
}

write_status() {
  local tmp now session tail state line
  tmp=$(mktemp)
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  {
    printf 'timestamp: %s\n' "$now"
    printf 'interval_seconds: %s\n' "$INTERVAL_SECONDS"
    printf 'managed_sessions: %s\n' "${KNOWN_SESSIONS[*]}"
    printf 'tasks:\n'
    printf '  1. docs/troubleshooting.md: %s' "$TASK1_STATUS"
    [[ -n "$TASK1_ASSIGNED_TO" ]] && printf ' (%s)' "$TASK1_ASSIGNED_TO"
    printf '\n'
    printf '  2. scripts/dws-cleanup.sh: %s' "$TASK2_STATUS"
    [[ -n "$TASK2_ASSIGNED_TO" ]] && printf ' (%s)' "$TASK2_ASSIGNED_TO"
    printf '\n'
    printf '  3. test all scripts: %s' "$TASK3_STATUS"
    [[ -n "$TASK3_ASSIGNED_TO" ]] && printf ' (%s)' "$TASK3_ASSIGNED_TO"
    printf '\n'
    printf 'actions:\n'
    if ((${#ACTIONS[@]} == 0)); then
      printf '  - none\n'
    else
      for line in "${ACTIONS[@]}"; do
        printf '  - %s\n' "$line"
      done
    fi
    printf 'sessions:\n'
    for session in "${SESSIONS[@]}"; do
      state="${SESSION_STATE[$session]:-unknown}"
      printf '  - %s: %s\n' "$session" "$state"
      tail="${SESSION_TAIL[$session]:-}"
      if [[ -n "${tail//[[:space:]]/}" ]]; then
        while IFS= read -r line; do
          printf '      %s\n' "$line"
        done <<<"$tail"
      fi
    done
  } >"$tmp"

  mv "$tmp" "$STATUS_FILE"
}

run_cycle() {
  local session_listing session tail state task
  local recreated=0

  unset ACTIONS SESSIONS SESSION_TAIL SESSION_STATE
  declare -ga ACTIONS SESSIONS
  declare -gA SESSION_TAIL SESSION_STATE
  ACTIONS=()
  SESSIONS=()
  SESSION_TAIL=()
  SESSION_STATE=()

  load_state
  refresh_task_status_from_files

  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    if ! array_contains "$session" "${KNOWN_SESSIONS[@]}"; then
      KNOWN_SESSIONS+=("$session")
      ACTIONS+=("discovered $session")
      set_last_state "$session" "unknown"
    fi
  done < <(discover_managed_sessions)

  for session in "${KNOWN_SESSIONS[@]}"; do
    if ! tmux has-session -t "$session" 2>/dev/null; then
      clear_assignments_for_session "$session"
      launch_session "$session"
      ACTIONS+=("recreated $session")
      recreated=1
      set_last_state "$session" "starting"
    fi
  done

  if ((recreated)); then
    sleep 5
  fi

  session_listing=$(tmux ls 2>&1 || true)
  if [[ "$session_listing" != *"no server running"* ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      session="${line%%:*}"
      SESSIONS+=("$session")
      tail=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -5 || true)
      SESSION_TAIL["$session"]="$tail"
      SESSION_STATE["$session"]="$(classify_tail "$tail")"
    done <<<"$session_listing"
  fi

  if [[ "$TASK3_STATUS" == "assigned" && -n "$TASK3_ASSIGNED_TO" ]]; then
    state="${SESSION_STATE[$TASK3_ASSIGNED_TO]:-missing}"
    if [[ "$state" == "busy" ]]; then
      TASK3_STARTED=1
    elif [[ "$state" == "idle" && "$TASK3_STARTED" == "1" ]]; then
      TASK3_STATUS="completed"
    fi
  fi

  for session in "${KNOWN_SESSIONS[@]}"; do
    state="${SESSION_STATE[$session]:-missing}"
    if [[ "$state" == "idle" ]] && ! session_has_pending_assignment "$session"; then
      if task=$(next_task_to_assign 2>/dev/null); then
        assign_task "$session" "$task"
        ACTIONS+=("assigned $(task_label "$task") to $session")
        SESSION_STATE["$session"]="assigned"
      fi
    fi
    set_last_state "$session" "$state"
  done

  save_state
  write_status
}

main() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    exit 0
  fi

  printf '%s\n' "$$" >"$PID_FILE"

  if ((RUN_ONCE)); then
    run_cycle
    return 0
  fi

  while true; do
    run_cycle
    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
