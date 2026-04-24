#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/dws-session-meta.sh"

die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
usage(){ cat <<EOF
usage: $(basename "$0") <project-short> <model-short>
projects: gs voice oclaw gsaq orch dws
models: 5-4 5-2 codex mini 5mini 4o opus sonnet haiku claude
EOF
}
tmux_q() {
  if [ -n "$TMUX_SOCKET" ]; then
    tmux -L "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}
attach() {
  local session="$1"
  if [ -n "${TMUX:-}" ]; then
    tmux_q switch-client -t "$session"
  else
    exec tmux_q attach-session -t "$session"
  fi
}
project(){ case "$1" in
  gs|global-sentinel) echo "global-sentinel|gs" ;;
  voice|wrkflo-voice-agents-ops) echo "wrkflo-voice-agents-ops|voice" ;;
  oclaw|openclaw-prod) echo "openclaw-prod|oclaw" ;;
  gsaq|global-sentinel-azure-quantum) echo "global-sentinel-azure-quantum|gsaq" ;;
  orch|wrkflo-orchestrator) echo "wrkflo-orchestrator|orch" ;;
  dws|dev-workspace) echo "dev-workspace|dws" ;;
  *) return 1 ;; esac
}
model(){ case "$1" in
  5.4|5-4|5_4|foundry-5_4) echo "5-4|foundry-5_4" ;;
  5.2|5-2|5_2|foundry-5_2) echo "5-2|foundry-5_2" ;;
  codex|foundry-codex) echo "codex|foundry-codex" ;;
  mini|foundry-mini) echo "mini|foundry-mini" ;;
  5mini|5-mini|foundry-5-mini) echo "5mini|foundry-5-mini" ;;
  4o|foundry-4o) echo "4o|foundry-4o" ;;
  opus|foundry-opus) echo "opus|foundry-opus" ;;
  sonnet|foundry-sonnet) echo "sonnet|foundry-sonnet" ;;
  haiku|foundry-haiku) echo "haiku|foundry-haiku" ;;
  claude) echo "claude|claude" ;;
  *) return 1 ;; esac
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { usage; exit 0; }
[ $# -eq 2 ] || { usage >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || die "tmux is required"

project_spec=$(project "$1") || { usage >&2; die "unknown project: $1"; }
IFS='|' read -r proj short <<<"$project_spec"
model_spec=$(model "$2") || { usage >&2; die "unknown model: $2"; }
IFS='|' read -r label profile <<<"$model_spec"
[ -d "$HOME/projects/$proj" ] || die "missing ~/projects/$proj"
session="${short}-${label}"
if tmux_q has-session -t "$session" 2>/dev/null; then
  printf 'reconnecting %s\n' "$session"
  attach "$session"
fi

if [ "$profile" = "claude" ]; then
  runner="claude --dangerously-skip-permissions"
else
  runner="codex --profile $profile --search --dangerously-bypass-approvals-and-sandbox"
fi
cmd="[ -n \"\${AZURE_OPENAI_API_KEY:-}\" ] || { [ -f '$HOME/.config/wrkflo/foundry.env' ] && . '$HOME/.config/wrkflo/foundry.env'; }; export MAC_GUI_URL='${MAC_GUI_URL:-}' MAC_CDP_URL='${MAC_CDP_URL:-}' MAC_SSH_HOST='${MAC_SSH_HOST:-}' DWS_PRIMARY_PROJECT='$proj' DWS_PRIMARY_MODEL='$label'; cd '$HOME/projects/$proj' && $runner; exec bash -l"
tmux_q new-session -d -s "$session" -c "$HOME/projects/$proj" "$cmd" || die "failed to create $session"
tmux_q set-option -t "$session" -q @dws_project "$proj"
tmux_q set-option -t "$session" -q @dws_model "$label"
tmux_q set-option -t "$session" -q @dws_profile "$profile"
tmux_q set-option -t "$session" -q @dws_task ""
dws_session_meta_write "$session" "$proj" "$label" "$profile" ""
printf 'launching %s\n' "$session"
attach "$session"
