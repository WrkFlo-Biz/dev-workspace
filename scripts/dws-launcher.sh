#!/usr/bin/env bash
# dws-launcher.sh — runs on SSH login to the dev-workspace VM.
# Two-step picker: project -> model/tool, wrapped in tmux for session persistence.
# If you disconnect (phone sleep, network drop), reconnect and your session is alive.
#
# Escape hatches:
#   - press q or ^C at the prompt to drop to a plain shell
#   - set SKIP_LAUNCHER=1 before SSH (or in Termius host env) to disable

set -u

[ -t 0 ] || return 0 2>/dev/null || exit 0
[ -z "${SKIP_LAUNCHER:-}" ] || return 0 2>/dev/null || exit 0
[ -z "${DWS_LAUNCHER_RAN:-}" ] || return 0 2>/dev/null || exit 0
export DWS_LAUNCHER_RAN=1

[ -n "${AZURE_OPENAI_API_KEY:-}" ] || {
  [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"
}

export MAC_GUI_URL="${MAC_GUI_URL:-http://100.78.207.22:9223}"
export MAC_CDP_URL="${MAC_CDP_URL:-http://100.78.207.22:9222}"
export MAC_SSH_HOST="${MAC_SSH_HOST:-mosestut@100.78.207.22}"
SESSIONS_TOOL="$HOME/projects/dev-workspace/scripts/dws-sessions.sh"
QUICK_TOOL="$HOME/projects/dev-workspace/scripts/dws-quick.sh"

# ── Helpers ──

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
bold()  { color '1'  "$1"; }
dim()   { color '2'  "$1"; }
green() { color '32' "$1"; }
cyan()  { color '36' "$1"; }
yellow(){ color '33' "$1"; }
red()   { color '31' "$1"; }

hr() { local w; w=$(tput cols 2>/dev/null || echo 40); printf '%*s\n' "$w" '' | tr ' ' '─'; }

host_info() {
  local h who
  h=$(hostname -s 2>/dev/null || echo "?")
  who=$(whoami)
  echo "$(bold "$who@$h")"
}

key_status() {
  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    green "ok"
  else
    red "missing"
  fi
}

# ── Project mapping ──

proj_name() {
  case "$1" in
    1) echo "global-sentinel" ;;
    2) echo "wrkflo-voice-agents-ops" ;;
    3) echo "openclaw-prod" ;;
    4) echo "global-sentinel-azure-quantum" ;;
    5) echo "wrkflo-orchestrator" ;;
    6) echo "dev-workspace" ;;
    *) echo "" ;;
  esac
}

proj_short() {
  case "$1" in
    global-sentinel) echo "gs" ;;
    wrkflo-voice-agents-ops) echo "voice" ;;
    openclaw-prod) echo "oclaw" ;;
    global-sentinel-azure-quantum) echo "gsaq" ;;
    wrkflo-orchestrator) echo "orch" ;;
    dev-workspace) echo "dws" ;;
    *) echo "proj" ;;
  esac
}

profile_for() {
  case "$1" in
    1) echo "foundry-5_4" ;;
    2) echo "foundry-5_2" ;;
    3) echo "foundry-codex" ;;
    4) echo "foundry-mini" ;;
    5) echo "foundry-5-mini" ;;
    6) echo "foundry-4o" ;;
    7) echo "foundry-opus" ;;
    8) echo "foundry-sonnet" ;;
    9) echo "foundry-haiku" ;;
    *) echo "" ;;
  esac
}

model_label() {
  case "$1" in
    1) echo "5-4" ;;
    2) echo "5-2" ;;
    3) echo "codex" ;;
    4) echo "mini" ;;
    5) echo "5mini" ;;
    6) echo "4o" ;;
    7) echo "opus" ;;
    8) echo "sonnet" ;;
    9) echo "haiku" ;;
    c|C) echo "claude" ;;
    *) echo "?" ;;
  esac
}

model_arg() {
  case "$1" in
    1) echo "5.4" ;;
    2) echo "5.2" ;;
    3) echo "codex" ;;
    4) echo "mini" ;;
    5) echo "5mini" ;;
    6) echo "4o" ;;
    7) echo "opus" ;;
    8) echo "sonnet" ;;
    9) echo "haiku" ;;
    c|C) echo "claude" ;;
    *) echo "" ;;
  esac
}

# ── tmux session management ──

list_sessions() {
  if [ -x "$SESSIONS_TOOL" ]; then
    "$SESSIONS_TOOL" list
  else
    tmux ls -F '#{session_name} #{?session_attached,attached,detached}' 2>/dev/null
  fi
}

session_count() {
  tmux ls 2>/dev/null | wc -l | tr -d ' '
}

session_names() {
  tmux ls -F '#{session_name}' 2>/dev/null
}

resolve_session_pick() {
  local pick="${1:-}" name
  [ -n "$pick" ] || return 1
  if tmux has-session -t "$pick" 2>/dev/null; then
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

attach_named_session() {
  local name="$1"
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$name"
  else
    exec tmux attach -t "$name"
  fi
}

launch_choice() {
  local proj="$1" choice="$2" short arg
  short=$(proj_short "$proj")
  arg=$(model_arg "$choice")
  if [ -n "$arg" ] && [ -x "$QUICK_TOOL" ]; then
    exec "$QUICK_TOOL" "$short" "$arg"
  fi
  return 1
}

# ── Workspace prompt injected into Codex/Claude ──

workspace_prompt() {
  local proj="$1"
  cat <<WEOF
Workspace root: \$HOME/projects.
Projects: global-sentinel, wrkflo-voice-agents-ops, openclaw-prod, global-sentinel-azure-quantum, wrkflo-orchestrator, dev-workspace.
Focus: $proj. Start there, inspect siblings under \$HOME/projects when asked.
Mac bridges: GUI=\$MAC_GUI_URL  CDP=\$MAC_CDP_URL  SSH=\$MAC_SSH_HOST
WEOF
}

# ── Launch into tmux ──

launch_tmux() {
  local proj="$1" tool="$2" session_name="$3"

  if [ ! -d "$HOME/projects/$proj" ]; then
    red "missing: ~/projects/$proj"; echo
    read -rp "press enter "
    return 1
  fi

  local cmd
  if [ "$tool" = "claude" ]; then
    cmd="cd $HOME/projects/$proj && claude --dangerously-skip-permissions"
  else
    cmd="cd $HOME/projects/$proj && codex --profile $tool --search --dangerously-bypass-approvals-and-sandbox"
  fi

  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "  $(green "reconnecting") to $session_name..."
    sleep 0.3
    exec tmux attach -t "$session_name"
  else
    echo "  $(green "launching") $session_name..."
    sleep 0.3
    exec tmux new-session -s "$session_name" -c "$HOME/projects/$proj" \
      "export AZURE_OPENAI_API_KEY='${AZURE_OPENAI_API_KEY:-}'; \
       export MAC_GUI_URL='${MAC_GUI_URL:-}'; \
       export MAC_CDP_URL='${MAC_CDP_URL:-}'; \
       export MAC_SSH_HOST='${MAC_SSH_HOST:-}'; \
       export DWS_PRIMARY_PROJECT='$proj'; \
       $cmd; exec bash -l"
  fi
}

# ── Status page ──

status_page() {
  clear 2>/dev/null || true
  echo
  bold "  active sessions"; echo
  if [ "$(session_count)" -gt 0 ]; then
    list_sessions | sed 's/^/    /'
  else
    dim "    (none)"; echo
  fi
  echo
  bold "  projects"; echo
  for d in "$HOME"/projects/*/; do
    local name branch dirty
    name=$(basename "$d")
    branch=$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null || echo "-")
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | head -1)
    if [ -n "$dirty" ]; then
      printf "    %-28s %s %s\n" "$name" "$branch" "$(yellow "*dirty")"
    else
      printf "    %-28s %s\n" "$name" "$branch"
    fi
  done
  echo
  bold "  system"; echo
  printf "    uptime: %s\n" "$(uptime -p 2>/dev/null || uptime)"
  printf "    disk:   %s\n" "$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}')"
  printf "    mem:    %s\n" "$(free -h | awk 'NR==2{print $3"/"$2" ("int($3/$2*100)"% used)"}')"
  printf "    key:    %s\n" "$(key_status)"
  echo
  bold "  tailnet"; echo
  sudo tailscale status 2>&1 | head -6 | sed 's/^/    /'
  echo
  read -rp "  press enter to return "
}

# ── Main loop ──

while :; do
  clear 2>/dev/null || true
  echo
  bold "  ⎈ dev-workspace · $(host_info)"; echo
  dim  "  Foundry key=$(key_status)"; echo
  hr

  # Show active sessions if any exist
  sc=$(session_count)
  if [ "$sc" -gt 0 ]; then
    echo
    bold "  Active sessions ($sc):"; echo
    list_sessions | sed 's/^/    /'
    echo
    cyan "  r"; echo -n "  reconnect to session"
    echo
    cyan "  k"; echo -n "  kill a session"
    echo
    cyan "  x"; echo -n "  cleanup sessions older than 24h"
    echo
    hr
  fi

  cat <<MENU

  $(bold "New session:")
  $(cyan 1)  Global Sentinel
  $(cyan 2)  Voice Agents Ops
  $(cyan 3)  OpenClaw Prod
  $(cyan 4)  GS Azure Quantum
  $(cyan 5)  Orchestrator
  $(cyan 6)  Dev Workspace
  $(cyan 7)  Plain shell
  $(cyan s)  Status / system info

  $(dim "q  quit / drop to bash")

MENU
  hr
  read -rp "  > " proj_choice

  case "$proj_choice" in
    r|R)
      if [ "$sc" -eq 0 ]; then
        yellow "  no active sessions"; echo; sleep 0.6
      elif [ "$sc" -eq 1 ]; then
        attach_named_session "$(session_names | sed -n '1p')"
      else
        echo
        bold "  Pick session:"; echo
        session_names | nl -w2 -s') '
        echo
        read -rp "  session name or #: " pick
        if [ -n "$pick" ]; then
          target=$(resolve_session_pick "$pick" || true)
          if [ -n "$target" ]; then
            attach_named_session "$target"
          else
            red "  session not found"; echo; sleep 0.6
          fi
        fi
      fi
      continue
      ;;
    k|K)
      if [ "$sc" -eq 0 ]; then
        yellow "  no active sessions"; echo; sleep 0.6
      else
        echo
        bold "  Kill session:"; echo
        session_names | nl -w2 -s') '
        echo
        read -rp "  session name or #: " pick
        target=$(resolve_session_pick "$pick" || true)
        if [ -n "$target" ]; then
          if [ -x "$SESSIONS_TOOL" ]; then
            "$SESSIONS_TOOL" kill "$target"
          else
            tmux kill-session -t "$target"
          fi
          sleep 0.7
        else
          red "  session not found"; echo; sleep 0.6
        fi
      fi
      continue
      ;;
    x|X)
      if [ "$sc" -eq 0 ]; then
        yellow "  no active sessions"; echo; sleep 0.6
      elif [ -x "$SESSIONS_TOOL" ]; then
        "$SESSIONS_TOOL" cleanup
        read -rp "  press enter "
      else
        yellow "  missing session tool"; echo; sleep 0.6
      fi
      continue
      ;;
    [1-6])
      proj=$(proj_name "$proj_choice")
      ;;
    7)
      cd "$HOME/projects" && exec bash -l
      ;;
    s|S)
      status_page; continue
      ;;
    q|Q|'')
      echo; exec bash -l
      ;;
    *)
      yellow "  unknown"; echo; sleep 0.4; continue
      ;;
  esac

  # Model sub-menu
  while :; do
    clear 2>/dev/null || true
    echo
    bold "  ⎈ $proj · select model"; echo
    hr
    cat <<MENU

  $(bold "── OpenAI ──")
  $(cyan 1)  gpt-5.4            $(dim "xhigh — hard bugs, planning")
  $(cyan 2)  gpt-5.2            $(dim "high  — general coding")
  $(cyan 3)  gpt-5.2-codex      $(dim "high  — code completions")
  $(cyan 4)  gpt-5.1-codex-mini $(dim "med   — quick edits")
  $(cyan 5)  gpt-5-mini         $(dim "med   — fast, cheap")
  $(cyan 6)  gpt-4o             $(dim "med   — multimodal")

  $(bold "── Claude ──")
  $(cyan 7)  claude-opus-4-6    $(dim "high  — complex reasoning")
  $(cyan 8)  claude-sonnet-4-6  $(dim "med   — balanced")
  $(cyan 9)  claude-haiku-4-5   $(dim "med   — fast Q&A")

  $(bold "── Other ──")
  $(cyan c)  Claude Code CLI    $(dim "      — native claude")

  $(dim "b  back")

MENU
    hr
    read -rp "  > " model_choice

    case "$model_choice" in
      [1-9])
        if launch_choice "$proj" "$model_choice"; then
          continue
        fi
        local_profile=$(profile_for "$model_choice")
        label=$(model_label "$model_choice")
        short=$(proj_short "$proj")
        session_name="${short}-${label}"
        if [ -n "$local_profile" ]; then
          launch_tmux "$proj" "$local_profile" "$session_name"
        fi
        ;;
      c|C)
        if launch_choice "$proj" "$model_choice"; then
          continue
        fi
        short=$(proj_short "$proj")
        session_name="${short}-claude"
        launch_tmux "$proj" "claude" "$session_name"
        ;;
      b|B|'')
        break
        ;;
      *)
        yellow "  unknown"; echo; sleep 0.4
        ;;
    esac
  done
done
