#!/usr/bin/env bash
set -euo pipefail

TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-$HOME/projects}"
CODEX_PROFILE="${DWS_SESSION_INIT_PROFILE:-foundry-5_4}"
FOUNDRY_ENV="${DWS_FOUNDRY_ENV:-$HOME/.config/wrkflo/foundry.env}"
MONITOR_SCRIPT="${DWS_SESSION_INIT_MONITOR_SCRIPT:-$HOME/bin/task-monitor.sh}"
VERIFY_TIMEOUT_SECONDS="${DWS_SESSION_INIT_TIMEOUT_SECONDS:-20}"
FORCE_RECREATE=0

SESSIONS=(
  dws-a
  dws-b
  worker-c
  worker-d
  worker-e
  worker-f
  worker-g
  worker-h
  orchestrator
  monitor
)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
usage: $(basename "$0") [--force] [--help]

Ensure the expected tmux runtime sessions exist:
  dws-a, dws-b, worker-c..worker-h, orchestrator, monitor

Options:
  --force  recreate every managed session even if it already looks healthy
EOF
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

pane_value() {
  local session="$1" format="$2"
  tmux_q list-panes -t "$session" -F "$format" 2>/dev/null | sed -n '1p'
}

pane_dead() {
  pane_value "$1" '#{pane_dead}'
}

pane_current_command() {
  pane_value "$1" '#{pane_current_command}'
}

capture_tail() {
  tmux_q capture-pane -p -t "$1" -S -80 2>/dev/null | tr -d '\r'
}

profile_label() {
  case "$1" in
    foundry-5_4) printf '%s\n' '5-4' ;;
    foundry-5_2) printf '%s\n' '5-2' ;;
    foundry-codex) printf '%s\n' 'codex' ;;
    foundry-mini) printf '%s\n' 'mini' ;;
    foundry-5-mini) printf '%s\n' '5mini' ;;
    foundry-4o) printf '%s\n' '4o' ;;
    foundry-opus) printf '%s\n' 'opus' ;;
    foundry-sonnet) printf '%s\n' 'sonnet' ;;
    foundry-haiku) printf '%s\n' 'haiku' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

session_kind() {
  case "$1" in
    monitor) printf '%s\n' 'monitor' ;;
    *) printf '%s\n' 'codex' ;;
  esac
}

session_repo() {
  case "$1" in
    orchestrator) printf '%s\n' 'wrkflo-orchestrator' ;;
    monitor) printf '%s\n' 'dev-workspace' ;;
    *) printf '%s\n' 'dev-workspace' ;;
  esac
}

session_cwd() {
  printf '%s/%s\n' "$PROJECTS_ROOT" "$(session_repo "$1")"
}

codex_command() {
  local repo_dir="$1"
  printf '%s' "bash --norc -c \"[ -f '$FOUNDRY_ENV' ] && . '$FOUNDRY_ENV' 2>/dev/null; cd '$repo_dir'; exec codex --profile '$CODEX_PROFILE' --search --dangerously-bypass-approvals-and-sandbox\""
}

monitor_command() {
  local cwd="$1"
  printf '%s' "bash --norc -c \"export SKIP_LAUNCHER=1; [ -f '$FOUNDRY_ENV' ] && . '$FOUNDRY_ENV' 2>/dev/null; cd '$cwd'; exec '$MONITOR_SCRIPT'\""
}

session_command() {
  local session="$1" cwd
  cwd=$(session_cwd "$session")
  case "$(session_kind "$session")" in
    monitor) monitor_command "$cwd" ;;
    codex) codex_command "$cwd" ;;
    *) return 1 ;;
  esac
}

set_codex_metadata() {
  local session="$1" repo="$2" label
  label=$(profile_label "$CODEX_PROFILE")
  tmux_q set-option -t "$session" -q @dws_project "$repo" >/dev/null 2>&1 || true
  tmux_q set-option -t "$session" -q @dws_model "$label" >/dev/null 2>&1 || true
  tmux_q set-option -t "$session" -q @dws_profile "$CODEX_PROFILE" >/dev/null 2>&1 || true
  tmux_q set-option -t "$session" -q @dws_task "" >/dev/null 2>&1 || true
}

session_ready() {
  local session="$1" kind="$2" command output
  session_exists "$session" || return 1
  [ "$(pane_dead "$session")" = "0" ] || return 1

  command=$(pane_current_command "$session")
  output=$(capture_tail "$session")

  case "$kind" in
    codex)
      case "$command" in
        node|codex) return 0 ;;
      esac
      printf '%s\n' "$output" | grep -Eq 'gpt-[0-9]|Working \(|(^|[[:space:]])› '
      ;;
    monitor)
      printf '%s\n' "$output" | grep -Eq '\[monitor\]|status written:'
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_ready() {
  local session="$1" kind="$2" elapsed=0
  while [ "$elapsed" -lt "$VERIFY_TIMEOUT_SECONDS" ]; do
    if session_ready "$session" "$kind"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

kill_session_if_present() {
  local session="$1"
  session_exists "$session" || return 0
  tmux_q kill-session -t "$session" >/dev/null 2>&1 || true
}

create_session() {
  local session="$1" kind repo cwd cmd
  kind=$(session_kind "$session")
  repo=$(session_repo "$session")
  cwd=$(session_cwd "$session")
  cmd=$(session_command "$session") || die "unknown session: $session"

  case "$kind" in
    codex)
      tmux_q new-session -d -s "$session" -c "$cwd" "$cmd" || die "failed to create $session"
      set_codex_metadata "$session" "$repo"
      ;;
    monitor)
      tmux_q new-session -d -s "$session" -c "$cwd" "$cmd" || die "failed to create $session"
      ;;
    *)
      die "unknown session kind for $session"
      ;;
  esac
}

ensure_requirements() {
  command -v tmux >/dev/null 2>&1 || die "tmux is required"
  command -v codex >/dev/null 2>&1 || die "codex is required"
  [ -d "${PROJECTS_ROOT}/dev-workspace" ] || die "missing ${PROJECTS_ROOT}/dev-workspace"
  [ -d "${PROJECTS_ROOT}/wrkflo-orchestrator" ] || die "missing ${PROJECTS_ROOT}/wrkflo-orchestrator"
  [ -x "$MONITOR_SCRIPT" ] || die "missing monitor script: $MONITOR_SCRIPT"
}

ensure_session() {
  local session="$1" kind repo state
  kind=$(session_kind "$session")
  repo=$(session_repo "$session")

  if [ "$FORCE_RECREATE" -eq 1 ]; then
    state="recreated"
    kill_session_if_present "$session"
    create_session "$session"
  elif session_ready "$session" "$kind"; then
    if [ "$kind" = "codex" ]; then
      set_codex_metadata "$session" "$repo"
    fi
    printf 'reused %s (%s)\n' "$session" "$kind"
    return 0
  else
    if session_exists "$session"; then
      state="recreated"
      kill_session_if_present "$session"
    else
      state="created"
    fi
    create_session "$session"
  fi

  if ! wait_for_ready "$session" "$kind"; then
    printf 'last output for %s:\n%s\n' "$session" "$(capture_tail "$session")" >&2
    die "session did not become ready: $session"
  fi

  printf '%s %s (%s)\n' "$state" "$session" "$kind"
}

verify_sessions() {
  local session kind
  for session in "${SESSIONS[@]}"; do
    kind=$(session_kind "$session")
    if ! session_ready "$session" "$kind"; then
      die "session is not healthy after init: $session"
    fi
    printf 'verified %s (%s)\n' "$session" "$(pane_current_command "$session")"
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE_RECREATE=1 ;;
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

ensure_requirements

for session in "${SESSIONS[@]}"; do
  ensure_session "$session"
done

verify_sessions
