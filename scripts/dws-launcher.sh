#!/usr/bin/env bash
# dws-launcher.sh — runs on SSH login to the dev-workspace VM.
# Shows a picker for "which project + which tool" so Termius connects
# feel like one-tap launches.
#
# Escape hatches:
#   - press q or ^C at the prompt to drop to a plain shell
#   - set SKIP_LAUNCHER=1 before SSH (or in Termius host env) to disable

set -u

# Only launch in interactive TTY shells, and only once per session.
[ -t 0 ] || return 0 2>/dev/null || exit 0
[ -z "${SKIP_LAUNCHER:-}" ] || return 0 2>/dev/null || exit 0
[ -z "${DWS_LAUNCHER_RAN:-}" ] || return 0 2>/dev/null || exit 0
export DWS_LAUNCHER_RAN=1

# Ensure Foundry key is loaded no matter how the shell was spawned.
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || {
  [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"
}

# Expose the Mac control paths to any agent launched from the VM.
export MAC_GUI_URL="${MAC_GUI_URL:-http://100.78.207.22:9223}"
export MAC_CDP_URL="${MAC_CDP_URL:-http://100.78.207.22:9222}"
export MAC_SSH_HOST="${MAC_SSH_HOST:-mosestut@100.78.207.22}"

workspace_prompt() {
  cat <<'EOF'
Workspace root: $HOME/projects.
Projects available here include:
- global-sentinel
- wrkflo-voice-agents-ops
- openclaw-prod
- global-sentinel-azure-quantum
- wrkflo-orchestrator
- dev-workspace

Primary focus for this session: $DWS_PRIMARY_PROJECT.
Start there, but you may inspect and edit sibling projects under $HOME/projects when asked.
The Mac control paths are:
- GUI / AppleScript bridge: $MAC_GUI_URL
- Chrome DevTools bridge: $MAC_CDP_URL
- SSH back to the Mac: $MAC_SSH_HOST
EOF
}

codex_cmd() {
  local profile="$1"
  printf '%s' "codex --profile $profile --search --dangerously-bypass-approvals-and-sandbox --add-dir \"\$HOME\" \"\$(workspace_prompt)\""
}

claude_cmd() {
  printf '%s' "claude --dangerously-skip-permissions --add-dir \"\$HOME\" \"\$(workspace_prompt)\""
}

# Small helpers
color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
bold()  { color '1'  "$1"; }
dim()   { color '2'  "$1"; }
green() { color '32' "$1"; }
cyan()  { color '36' "$1"; }

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

host_info() {
  local h ts who
  h=$(hostname -s 2>/dev/null || echo "?")
  who=$(whoami)
  if command -v tailscale >/dev/null 2>&1; then
    ts=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "")
    [ -n "$ts" ] && ts="  ts=$ts"
  fi
  echo "$(bold "$who@$h")$ts"
}

azure_line() {
  local key_state
  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    key_state="$(green ok)"
  else
    key_state="$(color 31 missing)"
  fi
  echo "Azure Foundry: moses-8586-resource (eastus2)  key=$key_state"
}

menu() {
  clear 2>/dev/null || true
  echo
  bold "   ⎈ dev-workspace  ·  $(host_info)"; echo
  dim   "   $(azure_line)"; echo
  hr
  cat <<MENU

  $(cyan 1)  Global Sentinel    — codex full-access (gpt-5.4)
  $(cyan 2)  Global Sentinel    — codex full-access (gpt-5.4 xhigh)
  $(cyan 3)  Global Sentinel    — Claude Code full-access
  $(cyan 4)  Voice Agents       — codex full-access (gpt-5.4)
  $(cyan 5)  OpenClaw           — codex full-access (gpt-5.4)
  $(cyan 6)  GS Azure Quantum   — codex full-access (gpt-5.4)
  $(cyan 7)  Orchestrator       — codex full-access (gpt-5.4)
  $(cyan 8)  Plain shell in ~/projects
  $(cyan 9)  Tailscale / system status

  $(dim "q  quit / drop to bash")

MENU
  hr
}

launch() {
  local proj="$1" cmd="$2"
  if [ ! -d "$HOME/projects/$proj" ]; then
    echo "$(color 31 "missing: ~/projects/$proj")"
    read -rp "press enter to return to menu "
    return 1
  fi
  cd "$HOME/projects" || return 1
  exec env DWS_PRIMARY_PROJECT="$proj" bash -lc "$cmd"
}

status_page() {
  clear 2>/dev/null || true
  bold "  tailnet"; echo
  sudo tailscale status 2>&1 | sed 's/^/    /'
  echo
  bold "  projects"; echo
  for d in "$HOME"/projects/*/; do
    local name; name=$(basename "$d")
    local branch; branch=$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null || echo "-")
    local ahead;  ahead=$(git -C "$d" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    printf "    %-32s branch=%s  ahead=%s\n" "$name" "$branch" "$ahead"
  done
  echo
  bold "  azure"; echo
  az account show --query "[name,user.name]" -o tsv 2>/dev/null | sed 's/^/    /'
  echo
  read -rp "press enter to return to menu "
}

while :; do
  menu
  read -rp "  choice: " choice
  case "$choice" in
    1) launch global-sentinel                "$(codex_cmd foundry)" ;;
    2) launch global-sentinel                "$(codex_cmd foundry-5_4)" ;;
    3) launch global-sentinel                "$(claude_cmd)" ;;
    4) launch wrkflo-voice-agents-ops        "$(codex_cmd foundry)" ;;
    5) launch openclaw-prod                  "$(codex_cmd foundry)" ;;
    6) launch global-sentinel-azure-quantum  "$(codex_cmd foundry)" ;;
    7) launch wrkflo-orchestrator            "$(codex_cmd foundry-5_4)" ;;
    8) cd "$HOME/projects" && exec bash -l ;;
    9) status_page ;;
    q|Q|'') echo; exec bash -l ;;
    *) echo "  $(color 33 "unknown choice")"; sleep 0.6 ;;
  esac
done
