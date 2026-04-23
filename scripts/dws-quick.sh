#!/usr/bin/env bash
set -u

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
g() { c '32' "$1"; }
r() { c '31' "$1"; }

die() { printf '%s\n' "$(r "$*")" >&2; exit 1; }
attach_session() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$1"
  else
    exec tmux attach -t "$1"
  fi
}

project_full() {
  case "$1" in
    gs|global-sentinel) echo "global-sentinel" ;;
    voice|wrkflo-voice-agents-ops) echo "wrkflo-voice-agents-ops" ;;
    oclaw|openclaw-prod) echo "openclaw-prod" ;;
    gsaq|global-sentinel-azure-quantum) echo "global-sentinel-azure-quantum" ;;
    orch|wrkflo-orchestrator) echo "wrkflo-orchestrator" ;;
    dws|dev-workspace) echo "dev-workspace" ;;
    *) return 1 ;;
  esac
}

project_short() {
  case "$1" in
    global-sentinel|gs) echo "gs" ;;
    wrkflo-voice-agents-ops|voice) echo "voice" ;;
    openclaw-prod|oclaw) echo "oclaw" ;;
    global-sentinel-azure-quantum|gsaq) echo "gsaq" ;;
    wrkflo-orchestrator|orch) echo "orch" ;;
    dev-workspace|dws) echo "dws" ;;
    *) return 1 ;;
  esac
}

model_display() {
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
    *) return 1 ;;
  esac
}

session_label() {
  case "$1" in
    5.4|5-4|5_4|foundry-5_4) echo "5-4" ;;
    5.2|5-2|5_2|foundry-5_2) echo "5-2" ;;
    codex|foundry-codex) echo "codex" ;;
    mini|foundry-mini) echo "mini" ;;
    5mini|5-mini|foundry-5-mini) echo "5mini" ;;
    4o|foundry-4o) echo "4o" ;;
    opus|foundry-opus) echo "opus" ;;
    sonnet|foundry-sonnet) echo "sonnet" ;;
    haiku|foundry-haiku) echo "haiku" ;;
    claude) echo "claude" ;;
    *) return 1 ;;
  esac
}

model_profile() {
  case "$1" in
    5.4|5-4|5_4|foundry-5_4) echo "foundry-5_4" ;;
    5.2|5-2|5_2|foundry-5_2) echo "foundry-5_2" ;;
    codex|foundry-codex) echo "foundry-codex" ;;
    mini|foundry-mini) echo "foundry-mini" ;;
    5mini|5-mini|foundry-5-mini) echo "foundry-5-mini" ;;
    4o|foundry-4o) echo "foundry-4o" ;;
    opus|foundry-opus) echo "foundry-opus" ;;
    sonnet|foundry-sonnet) echo "foundry-sonnet" ;;
    haiku|foundry-haiku) echo "foundry-haiku" ;;
    claude) echo "claude" ;;
    *) return 1 ;;
  esac
}

session_meta() {
  local name="$1" proj model path suffix
  IFS='|' read -r proj model path <<EOF
$(tmux display-message -p -t "$name" '#{@dws_project}|#{@dws_model}|#{pane_current_path}')
EOF
  if [ -z "$proj" ]; then
    proj=$(project_full "${path##*/}" 2>/dev/null || true)
    [ -n "$proj" ] || proj=$(project_full "${name%%-*}" 2>/dev/null || true)
  fi
  if [ -z "$model" ]; then
    suffix="${name#*-}"
    [ "$suffix" = "$name" ] && suffix=""
    model=$(model_display "$suffix" 2>/dev/null || true)
  fi
  printf '%s|%s\n' "${proj:-}" "${model:-}"
}

find_matching_session() {
  local want_proj="$1" want_model="$2" name proj model
  tmux has-session -t "$3" 2>/dev/null && { printf '%s\n' "$3"; return 0; }
  while IFS= read -r name; do
    IFS='|' read -r proj model <<EOF
$(session_meta "$name")
EOF
    [ "$proj" = "$want_proj" ] || continue
    [ "$model" = "$want_model" ] || continue
    printf '%s\n' "$name"
    return 0
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  return 1
}

build_cmd() {
  local proj="$1" model="$2" profile="$3" runner
  if [ "$profile" = "claude" ]; then
    runner="claude --dangerously-skip-permissions"
  else
    runner="codex --profile $profile --search --dangerously-bypass-approvals-and-sandbox"
  fi
  cat <<EOF
[ -n "\${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "\$HOME/.config/wrkflo/foundry.env" ] && . "\$HOME/.config/wrkflo/foundry.env"; }
export MAC_GUI_URL="${MAC_GUI_URL:-http://100.78.207.22:9223}"
export MAC_CDP_URL="${MAC_CDP_URL:-http://100.78.207.22:9222}"
export MAC_SSH_HOST="${MAC_SSH_HOST:-mosestut@100.78.207.22}"
export DWS_PRIMARY_PROJECT="$proj"
export DWS_PRIMARY_MODEL="$model"
cd "\$HOME/projects/$proj" && $runner
exec bash -l
EOF
}

usage() {
  cat <<EOF
usage: $(basename "$0") <gs|voice|oclaw|gsaq|orch|dws> <5.4|5.2|codex|mini|opus|sonnet|haiku|claude>
EOF
}

command -v tmux >/dev/null 2>&1 || die "tmux is required"
[ $# -eq 2 ] || { usage; exit 1; }

project=$(project_full "$1") || die "unknown project: $1"
short=$(project_short "$project") || die "unknown project: $1"
model=$(model_display "$2") || die "unknown model: $2"
label=$(session_label "$2") || die "unknown model: $2"
profile=$(model_profile "$2") || die "unknown model: $2"
session_name="${short}-${label}"

[ -d "$HOME/projects/$project" ] || die "missing ~/projects/$project"

match=$(find_matching_session "$project" "$model" "$session_name" || true)
if [ -n "$match" ]; then
  printf '%s\n' "$(g "reconnecting $match")"
  attach_session "$match"
  exit $?
fi

tmux new-session -d -s "$session_name" -c "$HOME/projects/$project" "$(build_cmd "$project" "$model" "$profile")" \
  || die "failed to create session: $session_name"
tmux set-option -t "$session_name" -q @dws_project "$project"
tmux set-option -t "$session_name" -q @dws_model "$model"
tmux set-option -t "$session_name" -q @dws_profile "$profile"

printf '%s\n' "$(g "launching $session_name")"
attach_session "$session_name"
