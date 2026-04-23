#!/usr/bin/env bash
set -u

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
b() { c '1;36' "$1"; }
g() { c '32' "$1"; }
y() { c '33' "$1"; }
r() { c '31' "$1"; }
d() { c '2' "$1"; }

die() { printf '%s\n' "$(r "$*")" >&2; exit 1; }
have_tmux() { command -v tmux >/dev/null 2>&1; }
session_names() { tmux list-sessions -F '#{session_name}' 2>/dev/null; }
session_exists() { tmux has-session -t "$1" 2>/dev/null; }

proj_alias() {
  case "$1" in
    global-sentinel|gs) echo "gs" ;;
    wrkflo-voice-agents-ops|voice) echo "voice" ;;
    openclaw-prod|oclaw) echo "oclaw" ;;
    global-sentinel-azure-quantum|gsaq) echo "gsaq" ;;
    wrkflo-orchestrator|orch) echo "orch" ;;
    dev-workspace|dws) echo "dws" ;;
    *) echo "${1:-?}" ;;
  esac
}

model_alias() {
  case "$1" in
    5.4|5-4|5_4|foundry-5_4) echo "5.4" ;;
    5.2|5-2|5_2|foundry-5_2) echo "5.2" ;;
    codex|foundry-codex) echo "codex" ;;
    mini|foundry-mini) echo "mini" ;;
    5mini|5-mini|foundry-5-mini) echo "5mini" ;;
    4o|foundry-4o) echo "4o" ;;
    opus|foundry-opus) echo "opus" ;;
    sonnet|foundry-sonnet) echo "sonnet" ;;
    haiku|foundry-haiku) echo "haiku" ;;
    claude) echo "claude" ;;
    *) echo "${1:-?}" ;;
  esac
}

age_brief() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    printf '%ss' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%sm' $((secs / 60))
  elif [ "$secs" -lt 86400 ]; then
    printf '%sh' $((secs / 3600))
  else
    printf '%sd' $((secs / 86400))
  fi
}

session_meta() {
  local name="$1" created attached proj model path suffix
  IFS='|' read -r created attached proj model path <<EOF
$(tmux display-message -p -t "$name" '#{session_created}|#{?session_attached,1,0}|#{@dws_project}|#{@dws_model}|#{pane_current_path}')
EOF
  if [ -z "$proj" ]; then
    proj=$(proj_alias "${path##*/}")
    [ "$proj" = "${path##*/}" ] && proj=$(proj_alias "${name%%-*}")
  fi
  if [ -z "$model" ]; then
    suffix="${name#*-}"
    [ "$suffix" = "$name" ] && suffix=""
    model=$(model_alias "$suffix")
  fi
  printf '%s|%s|%s|%s\n' "$created" "$attached" "$(proj_alias "$proj")" "$(model_alias "$model")"
}

state_label() {
  if [ "$1" = "1" ]; then
    g "attached"
  else
    d "detached"
  fi
}

line_for_session() {
  local name="$1" now created attached proj model age
  now=$(date +%s)
  IFS='|' read -r created attached proj model <<EOF
$(session_meta "$name")
EOF
  age=$(age_brief $((now - created)))
  printf '%-12s %-4s %-6s %-7s %s\n' \
    "$name" "$age" "$proj" "$model" "$(state_label "$attached")"
}

resolve_session() {
  local pick="${1:-}" name
  [ -n "$pick" ] || return 1
  if session_exists "$pick"; then
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

confirm() {
  local prompt="$1" ans
  read -r -p "$prompt [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

list_cmd() {
  if ! have_tmux || ! tmux list-sessions >/dev/null 2>&1; then
    d "no tmux sessions"; echo
    return 0
  fi
  printf '%-12s %-4s %-6s %-7s %s\n' \
    "$(b name)" "$(b age)" "$(b proj)" "$(b model)" "$(b state)"
  while IFS= read -r name; do
    line_for_session "$name"
  done < <(session_names)
}

attach_cmd() {
  local name
  name=$(resolve_session "${1:-}") || die "session not found: ${1:-}"
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$name"
  else
    exec tmux attach -t "$name"
  fi
}

kill_cmd() {
  local name
  name=$(resolve_session "${1:-}") || die "session not found: ${1:-}"
  tmux kill-session -t "$name" || die "failed to kill: $name"
  printf '%s\n' "$(y "killed $name")"
}

killall_cmd() {
  local count
  if ! have_tmux || ! tmux list-sessions >/dev/null 2>&1; then
    d "no tmux sessions"; echo
    return 0
  fi
  list_cmd
  echo
  count=$(session_names | wc -l | tr -d ' ')
  confirm "kill all $count sessions?" || { d "cancelled"; echo; return 1; }
  while IFS= read -r name; do
    [ -n "$name" ] && tmux kill-session -t "$name"
  done < <(session_names)
  printf '%s\n' "$(g "all sessions killed")"
}

cleanup_cmd() {
  local now name created attached proj model
  local -a old=()
  if ! have_tmux || ! tmux list-sessions >/dev/null 2>&1; then
    d "no tmux sessions"; echo
    return 0
  fi
  now=$(date +%s)
  while IFS= read -r name; do
    IFS='|' read -r created attached proj model <<EOF
$(session_meta "$name")
EOF
    [ $((now - created)) -ge 86400 ] && old+=("$name")
  done < <(session_names)
  if [ "${#old[@]}" -eq 0 ]; then
    d "no sessions older than 24h"; echo
    return 0
  fi
  printf '%-12s %-4s %-6s %-7s %s\n' \
    "$(b name)" "$(b age)" "$(b proj)" "$(b model)" "$(b state)"
  for name in "${old[@]}"; do
    line_for_session "$name"
  done
  echo
  confirm "kill ${#old[@]} old sessions?" || { d "cancelled"; echo; return 1; }
  for name in "${old[@]}"; do
    tmux kill-session -t "$name"
  done
  printf '%s\n' "$(g "old sessions cleaned")"
}

usage() {
  cat <<EOF
usage: $(basename "$0") list | attach <name> | kill <name> | killall | cleanup
EOF
}

case "${1:-list}" in
  list) list_cmd ;;
  attach) shift; attach_cmd "${1:-}" ;;
  kill) shift; kill_cmd "${1:-}" ;;
  killall) killall_cmd ;;
  cleanup) cleanup_cmd ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
