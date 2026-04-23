#!/usr/bin/env bash
# dws-health.sh — quick health dashboard for the dev workspace VM
set -u

c()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
bold() { c '1' "$1"; }
green(){ c '32' "$1"; }
red()  { c '31' "$1"; }
dim()  { c '2' "$1"; }
hr()   { echo '────────────────────────────────────────'; }

ok_or_fail() { [ "$1" = "0" ] && green "ok" || red "FAIL"; }

reach() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "$1" 2>/dev/null)
  [ "$code" -ge 200 ] && [ "$code" -lt 400 ] && echo 0 || echo 1
}

http() { curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "$1" 2>/dev/null; }

clear 2>/dev/null || true
echo
bold '  ⎈ dev-workspace health'; echo
hr

# System
bold '  system'; echo
printf '  uptime:  %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  disk:    %s\n' "$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}')"
printf '  memory:  %s\n' "$(free -h | awk 'NR==2{print $3"/"$2}')"
echo

# Tools
bold '  tools'; echo
printf '  codex:   %s\n' "$(codex --version 2>/dev/null || echo 'not found')"
printf '  claude:  %s\n' "$(claude --version 2>/dev/null || echo 'not found')"
printf '  gh:      %s\n' "$(gh auth status 2>&1 | grep -o 'Logged in to.*' || echo 'not authenticated')"
printf '  az:      %s\n' "$(az account show --query 'user.name' -o tsv 2>/dev/null || echo 'not authenticated')"
printf '  foundry: %s\n' "$([ -n "${AZURE_OPENAI_API_KEY:-}" ] && green 'key loaded' || red 'key MISSING')"
echo

# tmux sessions
bold '  sessions'; echo
if tmux ls 2>/dev/null | sed 's/^/  /'; then true; else dim '  (none)'; echo; fi
echo

# Projects
bold '  projects'; echo
for d in "$HOME"/projects/*/; do
  name=$(basename "$d")
  branch=$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null || echo '-')
  dirty=$(git -C "$d" status --porcelain 2>/dev/null | head -1)
  marker=$([ -n "$dirty" ] && echo ' *' || echo '')
  printf '  %-30s %s%s\n' "$name" "$branch" "$marker"
done
echo

# Services
bold '  services'; echo
orch_status=$(reach 'http://127.0.0.1:8787/healthz')
printf '  orchestrator:  %s  %s\n' "$(ok_or_fail $orch_status)" "http://127.0.0.1:8787"

mac_gui=$(reach "${MAC_GUI_URL:-http://100.78.207.22:9223}")
printf '  mac gui:       %s  %s\n' "$(ok_or_fail $mac_gui)" "${MAC_GUI_URL:-http://100.78.207.22:9223}"

mac_cdp=$(reach "${MAC_CDP_URL:-http://100.78.207.22:9222}")
printf '  mac cdp:       %s  %s\n' "$(ok_or_fail $mac_cdp)" "${MAC_CDP_URL:-http://100.78.207.22:9222}"
echo

# Tailscale
bold '  tailnet'; echo
sudo tailscale status 2>&1 | head -5 | sed 's/^/  /'
echo
