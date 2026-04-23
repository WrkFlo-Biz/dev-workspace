#!/usr/bin/env bash
# dws-launcher.sh — runs on SSH login to the dev-workspace VM.
# Two-step picker: project -> model/tool, so every Azure deployment is reachable.
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
yellow(){ color '33' "$1"; }

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

# ── Project menu ──

project_menu() {
  clear 2>/dev/null || true
  echo
  bold "   ⎈ dev-workspace  ·  $(host_info)"; echo
  dim   "   $(azure_line)"; echo
  hr
  cat <<MENU

  $(bold "Select project:")

  $(cyan 1)  Global Sentinel
  $(cyan 2)  Voice Agents Ops
  $(cyan 3)  OpenClaw Prod
  $(cyan 4)  GS Azure Quantum
  $(cyan 5)  Orchestrator
  $(cyan 6)  Plain shell in ~/projects
  $(cyan 7)  Tailscale / system status

  $(dim "q  quit / drop to bash")

MENU
  hr
}

# ── Model menu ──

model_menu() {
  local proj="$1"
  clear 2>/dev/null || true
  echo
  bold "   ⎈ $proj  ·  select model"; echo
  hr
  cat <<MENU

  $(bold "── OpenAI ──")
  $(cyan 1)  gpt-5.4          $(dim "xhigh  — architecture, hard bugs, planning")
  $(cyan 2)  gpt-5.2          $(dim "high   — general coding, medium tasks")
  $(cyan 3)  gpt-5.2-codex    $(dim "high   — code completions, diffs, tests")
  $(cyan 4)  gpt-5.1-codex-mini $(dim "med  — quick edits, small refactors")
  $(cyan 5)  gpt-5-mini       $(dim "med    — cheapest/fastest, trivial lookups")
  $(cyan 6)  gpt-4o           $(dim "med    — multimodal, images, long context")

  $(bold "── Claude (via Azure Foundry) ──")
  $(cyan 7)  claude-opus-4-6  $(dim "high   — complex reasoning, second opinion")
  $(cyan 8)  claude-sonnet-4-6 $(dim "med   — balanced, code review")
  $(cyan 9)  claude-haiku-4-5 $(dim "med    — fast, simple Q&A")

  $(bold "── Other ──")
  $(cyan c)  Claude Code CLI   $(dim "       — native claude, not codex")

  $(dim "b  back to project menu")

MENU
  hr
}

# Profile name for each model choice
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
  bold "  azure deployments"; echo
  az cognitiveservices account deployment list \
    --name moses-8586-resource --resource-group rg-moses-8586 \
    --query "[].name" -o tsv 2>/dev/null | sed 's/^/    /' || echo "    (az cli not authenticated)"
  echo
  bold "  system"; echo
  printf "    uptime: %s\n" "$(uptime -p 2>/dev/null || uptime)"
  printf "    disk:   %s\n" "$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}')"
  printf "    mem:    %s\n" "$(free -h | awk 'NR==2{print $3"/"$2" ("int($3/$2*100)"% used)"}')"
  echo
  read -rp "press enter to return to menu "
}

# ── Main loop ──

while :; do
  project_menu
  read -rp "  project: " proj_choice

  case "$proj_choice" in
    1) proj="global-sentinel" ;;
    2) proj="wrkflo-voice-agents-ops" ;;
    3) proj="openclaw-prod" ;;
    4) proj="global-sentinel-azure-quantum" ;;
    5) proj="wrkflo-orchestrator" ;;
    6) cd "$HOME/projects" && exec bash -l ;;
    7) status_page; continue ;;
    q|Q|'') echo; exec bash -l ;;
    *) echo "  $(yellow "unknown choice")"; sleep 0.6; continue ;;
  esac

  # Model sub-menu
  while :; do
    model_menu "$proj"
    read -rp "  model: " model_choice

    case "$model_choice" in
      [1-9])
        local_profile=$(profile_for "$model_choice")
        if [ -n "$local_profile" ]; then
          launch "$proj" "$(codex_cmd "$local_profile")"
        fi
        ;;
      c|C)
        launch "$proj" "$(claude_cmd)"
        ;;
      b|B|'')
        break
        ;;
      *)
        echo "  $(yellow "unknown choice")"; sleep 0.6
        ;;
    esac
  done
done
