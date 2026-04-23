#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/moses/projects/dev-workspace"
STATUS_FILE="/tmp/orchestrator-status.txt"
STATE_FILE="/tmp/orchestrator-handoff-state.sh"
LOCK_FILE="/tmp/orchestrator-handoff.lock"
PID_FILE="/tmp/orchestrator-handoff.pid"
INTERVAL_SECONDS="${ORCHESTRATOR_INTERVAL_SECONDS:-120}"
SESSIONS=(dws-a dws-b worker-c)

declare -a TASK_STATUS TASK_SESSION TASK_STARTED TASK_LABEL TASK_PROMPT
declare -a ACTIONS
declare -A SESSION_STATE SESSION_TAIL

TASK_LABEL[1]="scripts/dws-cron-setup.sh"
TASK_PROMPT[1]="Create scripts/dws-cron-setup.sh to install all crons: health every 15 minutes, cleanup weekly, and sync daily. Keep it focused under 80 lines, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[2]="Add --json flag to dws-health.sh"
TASK_PROMPT[2]="Add a --json flag to scripts/dws-health.sh for machine-readable output. Keep the patch focused and under 80 lines if possible, work only in $WORKDIR, run relevant checks, then git commit and push with a short summary including the commit."
TASK_LABEL[3]="scripts/dws-doctor.sh"
TASK_PROMPT[3]="Create scripts/dws-doctor.sh to diagnose common issues: Foundry key, Tailscale, git, disk, and required CLIs. Keep it focused under 80 lines, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[4]="config/codex-profiles/"
TASK_PROMPT[4]="Create config/codex-profiles/ as the source of truth for all 9 profile templates. Keep the changes focused, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[5]="ssh key setup in vm-setup.sh"
TASK_PROMPT[5]="Add SSH key setup to scripts/vm-setup.sh. Keep the change focused and under 80 lines if possible, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[6]="docs/runbook.md"
TASK_PROMPT[6]="Create docs/runbook.md covering start and stop, backup, restore, and upgrade operations. Keep it focused, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[7]="scripts/dws-tunnel.sh"
TASK_PROMPT[7]="Create scripts/dws-tunnel.sh as a port-forwarding helper. Keep it focused under 80 lines, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[8]="improve dws-launcher.sh"
TASK_PROMPT[8]="Improve scripts/dws-launcher.sh with a session count badge and the latest health result in the header. Keep the patch focused, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[9]=".github/workflows/lint.yml"
TASK_PROMPT[9]="Add .github/workflows/lint.yml to run shellcheck on push. Keep the patch focused, work in $WORKDIR, run relevant checks, then git commit and push with a short summary."
TASK_LABEL[10]="Test all scripts end-to-end"
TASK_PROMPT[10]="Test all scripts end-to-end in $WORKDIR, fix any bugs you find, run the relevant checks, then git commit and push with a short summary."

init_state() {
  TASK_STATUS=()
  TASK_SESSION=()
  TASK_STARTED=()
  for id in $(seq 1 10); do
    TASK_STATUS[$id]="pending"
    TASK_SESSION[$id]=""
    TASK_STARTED[$id]=0
  done

  # Preserve the tasks already in flight when the handoff monitor starts.
  TASK_STATUS[1]="assigned"
  TASK_SESSION[1]="dws-b"
  TASK_STARTED[1]=1
  TASK_STATUS[2]="assigned"
  TASK_SESSION[2]="worker-c"
  TASK_STARTED[2]=1
  TASK_STATUS[4]="assigned"
  TASK_SESSION[4]="dws-a"
  TASK_STARTED[4]=1
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    init_state
  fi
}

save_state() {
  local tmp
  tmp=$(mktemp)
  {
    declare -p TASK_STATUS
    declare -p TASK_SESSION
    declare -p TASK_STARTED
  } >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

session_task() {
  local session id
  session="$1"
  for id in $(seq 1 10); do
    if [[ "${TASK_STATUS[$id]:-pending}" == "assigned" && "${TASK_SESSION[$id]:-}" == "$session" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

next_task() {
  local id
  for id in $(seq 1 10); do
    if [[ "${TASK_STATUS[$id]:-pending}" == "pending" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

classify_tail() {
  local tail
  tail="$1"
  if grep -q 'Working (' <<<"$tail"; then
    printf '%s\n' "busy"
  elif grep -q 'gpt-5' <<<"$tail" || grep -q 'tab to queue message' <<<"$tail" || grep -q '^› ' <<<"$tail"; then
    printf '%s\n' "idle"
  elif [[ -z "${tail//[[:space:]]/}" ]]; then
    printf '%s\n' "unknown"
  else
    printf '%s\n' "busy"
  fi
}

replace_session() {
  local session task
  session="$1"
  if task=$(session_task "$session" 2>/dev/null); then
    TASK_STATUS[$task]="pending"
    TASK_SESSION[$task]=""
    TASK_STARTED[$task]=0
  fi
  tmux new-session -d -s "$session" -c "$WORKDIR" "source ~/.config/wrkflo/foundry.env; codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox; exec bash -l"
  ACTIONS+=("recreated $session")
}

capture_session() {
  local session tail
  session="$1"
  tail=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -20 || true)
  SESSION_TAIL["$session"]="$tail"
  SESSION_STATE["$session"]="$(classify_tail "$tail")"
}

assign_task() {
  local session id state
  session="$1"
  id="$2"
  tmux send-keys -t "$session" C-u "${TASK_PROMPT[$id]}" Enter
  TASK_STATUS[$id]="assigned"
  TASK_SESSION[$id]="$session"
  TASK_STARTED[$id]=0
  ACTIONS+=("assigned ${TASK_LABEL[$id]} to $session")

  sleep 5
  capture_session "$session"
  state="${SESSION_STATE[$session]}"
  if [[ "$state" == "idle" ]]; then
    tmux send-keys -t "$session" Enter
    ACTIONS+=("resent Enter to $session")
    sleep 5
    capture_session "$session"
    state="${SESSION_STATE[$session]}"
  fi
  if [[ "$state" == "busy" ]]; then
    TASK_STARTED[$id]=1
  fi
}

write_status() {
  local tmp now id session task line
  tmp=$(mktemp)
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf 'timestamp: %s\n' "$now"
    printf 'interval_seconds: %s\n' "$INTERVAL_SECONDS"
    printf 'sessions:\n'
    for session in "${SESSIONS[@]}"; do
      task=""
      if task=$(session_task "$session" 2>/dev/null); then
        printf '  - %s: %s (task %s: %s)\n' "$session" "${SESSION_STATE[$session]:-missing}" "$task" "${TASK_LABEL[$task]}"
      else
        printf '  - %s: %s\n' "$session" "${SESSION_STATE[$session]:-missing}"
      fi
      while IFS= read -r line; do
        printf '      %s\n' "$line"
      done <<<"${SESSION_TAIL[$session]:-}"
    done
    printf 'tasks:\n'
    for id in $(seq 1 10); do
      printf '  %s. %s: %s' "$id" "${TASK_LABEL[$id]}" "${TASK_STATUS[$id]}"
      [[ -n "${TASK_SESSION[$id]}" ]] && printf ' (%s)' "${TASK_SESSION[$id]}"
      printf '\n'
    done
    printf 'actions:\n'
    if ((${#ACTIONS[@]} == 0)); then
      printf '  - none\n'
    else
      for line in "${ACTIONS[@]}"; do
        printf '  - %s\n' "$line"
      done
    fi
  } >"$tmp"
  mv "$tmp" "$STATUS_FILE"
}

run_cycle() {
  local session state task next
  ACTIONS=()
  SESSION_STATE=()
  SESSION_TAIL=()
  load_state

  tmux ls >/dev/null
  for session in "${SESSIONS[@]}"; do
    if ! tmux has-session -t "$session" 2>/dev/null; then
      replace_session "$session"
      sleep 8
    fi
    capture_session "$session"
  done

  for session in "${SESSIONS[@]}"; do
    state="${SESSION_STATE[$session]}"
    if task=$(session_task "$session" 2>/dev/null); then
      if [[ "$state" == "busy" ]]; then
        TASK_STARTED[$task]=1
      elif [[ "$state" == "idle" && "${TASK_STARTED[$task]}" == "1" ]]; then
        TASK_STATUS[$task]="completed"
        TASK_SESSION[$task]=""
        TASK_STARTED[$task]=0
        ACTIONS+=("completed ${TASK_LABEL[$task]} on $session")
      fi
    fi
  done

  for session in "${SESSIONS[@]}"; do
    state="${SESSION_STATE[$session]}"
    if [[ "$state" == "idle" ]] && ! session_task "$session" >/dev/null 2>&1; then
      if next=$(next_task 2>/dev/null); then
        assign_task "$session" "$next"
      fi
    fi
  done

  save_state
  write_status
}

main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 0
  printf '%s\n' "$$" >"$PID_FILE"

  if [[ "${1:-}" == "--once" ]]; then
    run_cycle
    exit 0
  fi

  while true; do
    run_cycle
    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
