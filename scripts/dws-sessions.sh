#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_TOOL="${SCRIPT_DIR}/../bin/dws-sessions.sh"

if [ -x "$BIN_TOOL" ]; then
  exec "$BIN_TOOL" "$@"
fi

die() { printf '%s\n' "$*" >&2; exit 1; }
have_tmux() { command -v tmux >/dev/null 2>&1; }
rows() { tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_created}|#{session_last_attached}|#{@dws_project}|#{@dws_model}|#{pane_current_path}' 2>/dev/null; }
session_names() { rows | cut -d'|' -f1; }
session_exists() { tmux has-session -t "$1" 2>/dev/null; }

proj_name() {
  case "$1" in
    1) echo "global-sentinel" ;; 2) echo "wrkflo-voice-agents-ops" ;; 3) echo "openclaw-prod" ;;
    4) echo "global-sentinel-azure-quantum" ;; 5) echo "wrkflo-orchestrator" ;; 6) echo "dev-workspace" ;; *) echo "" ;;
  esac
}

proj_short() {
  case "$1" in
    global-sentinel|gs) echo "gs" ;; wrkflo-voice-agents-ops|voice) echo "voice" ;; openclaw-prod|oclaw) echo "oclaw" ;;
    global-sentinel-azure-quantum|gsaq) echo "gsaq" ;; wrkflo-orchestrator|orch) echo "orch" ;; dev-workspace|dws) echo "dws" ;; *) echo "${1:-?}" ;;
  esac
}

model_label() {
  case "$1" in
    1|5.4|5-4|5_4|foundry-5_4) echo "5-4" ;; 2|5.2|5-2|5_2|foundry-5_2) echo "5-2" ;;
    3|codex|foundry-codex) echo "codex" ;; 4|mini|foundry-mini) echo "mini" ;; 5|5mini|5-mini|foundry-5-mini) echo "5mini" ;;
    6|4o|foundry-4o) echo "4o" ;; 7|opus|foundry-opus) echo "opus" ;; 8|sonnet|foundry-sonnet) echo "sonnet" ;;
    9|haiku|foundry-haiku) echo "haiku" ;; c|C|claude) echo "claude" ;; *) echo "${1:-?}" ;;
  esac
}

usage() {
  cat <<EOF
usage: $(basename "$0") [list|kill <name>|kill-all|reconnect [name]|--help]
EOF
}

session_name() {
  local pick="${1:-}" name
  [ -n "$pick" ] || return 1
  session_exists "$pick" && { printf '%s\n' "$pick"; return 0; }
  case "$pick" in
    ''|*[!0-9]*) return 1 ;;
    *) name=$(session_names | sed -n "${pick}p"); [ -n "$name" ] || return 1; printf '%s\n' "$name" ;;
  esac
}

attach_session() {
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$1"; else exec tmux attach -t "$1"; fi
}

fmt_created() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }
need_sessions() { have_tmux && rows >/dev/null || return 1; }

list_cmd() {
  need_sessions || { echo "no tmux sessions"; return 0; }
  printf '%-16s %-7s %-7s %-3s %s\n' "name" "project" "model" "win" "created"
  while IFS='|' read -r name wins created _ proj model path; do
    printf '%-16s %-7s %-7s %-3s %s\n' \
      "$name" "$(proj_short "${proj:-${path##*/}}")" "$(model_label "${model:-${name#*-}}")" "$wins" "$(fmt_created "$created")"
  done < <(rows | sort -t'|' -k3,3nr)
}

reconnect_cmd() {
  local name="${1:-}"
  need_sessions || die "no tmux sessions"
  if [ -n "$name" ]; then
    name=$(session_name "$name") || die "session not found: $1"
  else
    name=$(rows | sort -t'|' -k4,4nr -k3,3nr | sed -n '1s/|.*//p')
  fi
  [ -n "$name" ] || die "no tmux sessions"
  attach_session "$name"
}

kill_cmd() {
  local name
  need_sessions || die "no tmux sessions"
  name=$(session_name "${1:-}") || die "session not found: ${1:-}"
  tmux kill-session -t "$name" || die "failed to kill: $name"
  printf 'killed %s\n' "$name"
}

kill_all_cmd() {
  local name
  need_sessions || { echo "no tmux sessions"; return 0; }
  while IFS= read -r name; do [ -n "$name" ] && tmux kill-session -t "$name"; done < <(session_names)
  echo "all sessions killed"
}

cleanup_cmd() {
  local now name created hit=0
  need_sessions || { echo "no tmux sessions"; return 0; }
  now=$(date +%s)
  while IFS='|' read -r name _ created _ _ _ _; do
    [ $((now - created)) -lt 86400 ] || { tmux kill-session -t "$name"; hit=1; }
  done < <(rows)
  [ "$hit" -eq 1 ] && echo "old sessions cleaned" || echo "no sessions older than 24h"
}

case "${1:-list}" in
  list) list_cmd ;;
  reconnect|attach) shift; reconnect_cmd "${1:-}" ;;
  kill) shift; kill_cmd "${1:-}" ;;
  kill-all|killall) kill_all_cmd ;;
  cleanup) cleanup_cmd ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
