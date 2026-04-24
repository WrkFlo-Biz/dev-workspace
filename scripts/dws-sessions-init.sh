#!/usr/bin/env bash
# dws-sessions-init.sh — create the managed tmux session pool on boot
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-${HOME}/projects}"
TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"
TIMEOUT_SECONDS="${DWS_SESSION_INIT_TIMEOUT_SECONDS:-15}"
FOUNDRY_ENV_PATH="${DWS_FOUNDRY_ENV_PATH:-${HOME}/.config/wrkflo/foundry.env}"

SESSION_SPECS=(
  "dws-a|dev-workspace|codex|5-4|foundry-5_4"
  "dws-b|dev-workspace|codex|5-4|foundry-5_4"
  "worker-c|dev-workspace|codex|5-4|foundry-5_4"
  "worker-d|dev-workspace|codex|5-4|foundry-5_4"
  "worker-e|dev-workspace|codex|5-4|foundry-5_4"
  "worker-f|dev-workspace|codex|5-2|foundry-5_2"
  "worker-g|dev-workspace|codex|5-4|foundry-5_4"
  "worker-h|dev-workspace|codex|5-2|foundry-5_2"
  "worker-i|dev-workspace|codex|5-4|foundry-5_4"
  "orchestrator|wrkflo-orchestrator|codex|5-4|foundry-5_4"
)

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dws-session-meta.sh"

log() {
  printf '%s [sessions-init] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  log "error: $*"
  exit 1
}

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

tmux_q() {
  if [ -n "$TMUX_SOCKET" ]; then
    tmux -L "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

session_exists() {
  tmux_q has-session -t "$1" 2>/dev/null
}

session_command() {
  tmux_q list-panes -t "$1" -F '#{pane_current_command}' 2>/dev/null | sed -n '1p'
}

session_path() {
  tmux_q list-panes -t "$1" -F '#{pane_current_path}' 2>/dev/null | sed -n '1p'
}

shell_name() {
  case "${1:-}" in
    bash|sh|dash|zsh|ksh|fish) return 0 ;;
    *) return 1 ;;
  esac
}

session_set_option() {
  local session="${1:-}" option="${2:-}" value="${3:-}"
  [ -n "$session" ] || return 1
  [ -n "$option" ] || return 1
  tmux_q set-option -t "$session" -q "$option" "$value" >/dev/null 2>&1 || true
}

persist_session_metadata() {
  local session="${1:-}" project="${2:-}" model="${3:-}" profile="${4:-}"
  [ -n "$session" ] || return 1

  session_set_option "$session" @dws_project "$project"
  session_set_option "$session" @dws_model "$model"
  session_set_option "$session" @dws_profile "$profile"
  session_set_option "$session" @dws_task ""
  dws_session_meta_write "$session" "$project" "$model" "$profile" "" >/dev/null 2>&1 || true
}

wait_for_tmux_server() {
  local attempt

  for attempt in $(seq 1 "$TIMEOUT_SECONDS"); do
    if tmux_q start-server >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "tmux server unavailable after ${TIMEOUT_SECONDS}s"
}

session_start_command() {
  local project_dir="${1:-}" profile="${2:-}"

  printf '%s' "source '${FOUNDRY_ENV_PATH}' 2>/dev/null || true; "
  printf '%s' "cd '${project_dir}'; "
  printf '%s' "exec codex --profile '${profile}' --search --dangerously-bypass-approvals-and-sandbox"
}

wait_for_session_ready() {
  local session="${1:-}" expected_dir="${2:-}" deadline command current_dir

  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if session_exists "$session"; then
      command=$(session_command "$session")
      current_dir=$(session_path "$session")
      if [ -n "$command" ] && ! shell_name "$command"; then
        log "verified ${session} (${command})"
        return 0
      fi
      if [ -n "$command" ] && [ -n "$expected_dir" ] && [ "$current_dir" != "$expected_dir" ]; then
        sleep 1
        continue
      fi
    fi
    sleep 1
  done

  if ! session_exists "$session"; then
    die "session ${session} exited before it became ready"
  fi

  command=$(session_command "$session")
  current_dir=$(session_path "$session")
  die "session ${session} did not become ready within ${TIMEOUT_SECONDS}s (command=${command:-unknown} path=${current_dir:-unknown})"
}

ensure_session() {
  local spec="$1"
  local session project kind model profile project_dir start_command

  IFS='|' read -r session project kind model profile <<EOF
$spec
EOF

  [ -n "$session" ] || die "invalid session spec: ${spec}"
  project_dir="${PROJECTS_ROOT}/${project}"
  [ -d "$project_dir" ] || die "missing project directory for ${session}: ${project_dir}"

  if session_exists "$session"; then
    persist_session_metadata "$session" "$project" "$model" "$profile"
    log "reused ${session} (${kind})"
    wait_for_session_ready "$session" "$project_dir"
    return 0
  fi

  start_command=$(session_start_command "$project_dir" "$profile")
  tmux_q new-session -d -s "$session" -c "$project_dir" "$start_command"
  persist_session_metadata "$session" "$project" "$model" "$profile"
  log "created ${session} (${kind})"
  wait_for_session_ready "$session" "$project_dir"
}

command -v tmux >/dev/null 2>&1 || die "tmux is required"
command -v codex >/dev/null 2>&1 || die "codex is required"
is_int "$TIMEOUT_SECONDS" || die "DWS_SESSION_INIT_TIMEOUT_SECONDS must be an integer"
[ "$TIMEOUT_SECONDS" -ge 1 ] || die "DWS_SESSION_INIT_TIMEOUT_SECONDS must be at least 1"

wait_for_tmux_server

for spec in "${SESSION_SPECS[@]}"; do
  ensure_session "$spec"
done

log "sessions init complete: ${#SESSION_SPECS[@]} sessions"
