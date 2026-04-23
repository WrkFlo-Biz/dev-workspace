#!/usr/bin/env bash
set -u
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"; }
: "${MAC_GUI_URL:=http://100.78.207.22:9223}"
: "${MAC_CDP_URL:=http://100.78.207.22:9222}"
ORCHESTRATOR_HEALTH_URL="${DWS_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"

c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }
g(){ c 32 "$1"; }
y(){ c 33 "$1"; }
r(){ c 31 "$1"; }
h(){ c '1;36' "$1"; }
d(){ c 2 "$1"; }
sec(){ printf '\n%s\n' "$(h "== $1 ==")"; }
have(){ command -v "$1" >/dev/null 2>&1; }
http(){
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null) || { printf 'ERR'; return; }
  printf '%s' "$code"
}
paint(){ case "$1" in 2??) g "$1" ;; 3??) y "$1" ;; *) r "$1" ;; esac; }
reach(){ case "$1" in 000|ERR) r "$1" ;; *) g "$1" ;; esac; }
ver(){ case "$1" in tmux) tmux -V 2>/dev/null ;; *) "$1" --version 2>/dev/null | sed -n '1p' ;; esac; }
usage(){ printf 'usage: %s [--json]\n' "$(basename "$0")"; }
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
fmt_dirty(){
  if [ -n "${1:-}" ]; then
    y "dirty"
  else
    g "clean"
  fi
}
fmt_foundry_key(){
  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    g "loaded"
  else
    r "missing"
  fi
}
fmt_tool_version(){
  if have "$1"; then
    ver "$1"
  else
    r "missing"
  fi
}
fmt_tailnet_connected(){
  if tailnet_connected; then
    g "yes"
  else
    r "no"
  fi
}
json_sessions(){
  local first=1 name
  printf '['
  if have tmux && tmux ls >/dev/null 2>&1; then
    while IFS= read -r name; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '"%s"' "$(jesc "$name")"
    done < <(tmux ls -F '#{session_name}' 2>/dev/null)
  fi
  printf ']'
}
json_projects(){
  local first=1 d n b dirty
  printf '['
  for d in "$HOME"/projects/*; do
    [ -e "$d" ] || continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    n=$(basename "$d")
    b=$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$d" rev-parse --short HEAD 2>/dev/null)
    dirty=false; git -C "$d" status --porcelain --ignore-submodules=dirty 2>/dev/null | sed -n '1q' | grep -q . && dirty=true
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '\n    {"name":"%s","branch":"%s","dirty":%s}' "$(jesc "$n")" "$(jesc "$b")" "$dirty"
  done
  [ "$first" -eq 1 ] || printf '\n  '
  printf ']'
}
case "${1:-}" in
  --json)
    gh_ok=false; have gh && gh auth status >/dev/null 2>&1 && gh_ok=true
    orch_code=$(http "$ORCHESTRATOR_HEALTH_URL")
    orch_ok=false; case "$orch_code" in 2??) orch_ok=true ;; esac
    printf '{\n'
    printf '  "system":{"hostname":"%s","uptime":"%s","disk":"%s","memory":"%s"},\n' \
      "$(jesc "$(hostname -s 2>/dev/null || hostname)")" "$(jesc "$(uptime -p 2>/dev/null || uptime)")" \
      "$(jesc "$(df -h / | awk 'NR == 2 { print $3 "/" $2 " (" $5 " used)" }')")" "$(jesc "$(free -h | awk 'NR == 2 { print $3 "/" $2 " used" }')")"
    printf '  "tools":{"codex_version":"%s","claude_version":"%s","gh_auth":%s,"foundry_key_loaded":%s},\n' \
      "$(jesc "$(have codex && ver codex || echo missing)")" "$(jesc "$(have claude && ver claude || echo missing)")" "$gh_ok" "$([ -n "${AZURE_OPENAI_API_KEY:-}" ] && echo true || echo false)"
    printf '  "services":{"orchestrator_api":{"url":"%s","http_code":"%s","reachable":%s}},\n' \
      "$(jesc "$ORCHESTRATOR_HEALTH_URL")" "$(jesc "$orch_code")" "$orch_ok"
    printf '  "sessions":'; json_sessions; printf ',\n'
    printf '  "projects":'; json_projects; printf '\n'
    printf '}\n'
    exit 0
    ;;
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
tailnet_connected(){ have tailscale && tailscale status >/dev/null 2>&1; }
tailnet_peers(){
  local self
  self=$(tailscale ip -4 2>/dev/null | sed -n '1p')
  tailscale status --peers 2>/dev/null | awk -v self="$self" '
    $1 != self && $5 != "-" {
      s = $5; for (i = 6; i <= NF; i++) s = s " " $i
      printf "  %-24s %-6s %s\n", $2, $4, s
      found = 1
    }
    END { if (!found) print "  none connected" }'
}
tailnet_ping(){
  local label="$1" ip="$2" out lat
  out=$(tailscale ping -c 1 "$ip" 2>/dev/null | sed -n '1p')
  lat=$(printf '%s\n' "$out" | sed -n 's/.* in \([^ ]*\)$/\1/p')
  [ -n "$lat" ] && printf '  %-12s %s\n' "$label" "$(g "$lat")" || printf '  %-12s %s\n' "$label" "$(r unreachable)"
}

if [ -t 1 ]; then
  clear 2>/dev/null || true
fi
printf '%s %s\n' "$(h 'Dev Workspace Health')" "$(d "$(date '+%Y-%m-%d %H:%M:%S %Z')")"

sec "tmux Sessions"
if have tmux && tmux ls >/dev/null 2>&1; then
  tmux ls -F '  #{session_name}  #{?session_attached,attached,detached}  #{session_windows}w'
else
  echo "  no tmux sessions"
fi

sec "Projects"
for d in "$HOME"/projects/*; do
  [ -e "$d" ] || continue
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
  n=$(basename "$d")
  b=$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$d" rev-parse --short HEAD 2>/dev/null)
  if git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    IFS=$'\t ' read -r behind ahead <<<"$(git -C "$d" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
    div="+${ahead:-0}/-${behind:-0}"
  else
    div="no-upstream"
  fi
  dirty=$(git -C "$d" status --porcelain --ignore-submodules=dirty 2>/dev/null | sed -n '1p')
  printf '  %-30s %-14s %-12s %s\n' "$n" "$b" "$div" "$(fmt_dirty "$dirty")"
done

sec "Tooling"
printf '  foundry key  %s\n' "$(fmt_foundry_key)"
printf '  codex        %s\n' "$(fmt_tool_version codex)"
printf '  claude       %s\n' "$(fmt_tool_version claude)"

sec "Auth"
if have gh && gh auth status >/dev/null 2>&1; then
  gh_user=$(gh auth status 2>/dev/null | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)
  printf '  gh           %s\n' "$(g "${gh_user:-ok}")"
else
  printf '  gh           %s\n' "$(r missing)"
fi
if have az; then
  az_acct=$(az account show --query '[user.name,name]' -o tsv 2>/dev/null | paste -sd'|' -)
  [ -n "$az_acct" ] && printf '  az           %s\n' "$(g "$az_acct")" || printf '  az           %s\n' "$(r missing)"
else
  printf '  az           %s\n' "$(r missing)"
fi

sec "System"
printf '  disk         %s\n' "$(df -h / | awk 'NR == 2 { print $3 "/" $2 " (" $5 " used)" }')"
printf '  memory       %s\n' "$(free -h | awk 'NR == 2 { print $3 "/" $2 " used" }')"
printf '  uptime       %s\n' "$(uptime -p 2>/dev/null || uptime)"

sec "Services"
printf '  orchestrator %s  %s\n' "$(paint "$(http "$ORCHESTRATOR_HEALTH_URL")")" "$ORCHESTRATOR_HEALTH_URL"
printf '  mac gui      %s  %s\n' "$(reach "$(http "$MAC_GUI_URL")")" "$MAC_GUI_URL"
printf '  mac cdp      %s  %s\n' "$(reach "$(http "$MAC_CDP_URL")")" "$MAC_CDP_URL"

sec "Tailnet"
if have tailscale; then
  printf '  connected    %s\n' "$(fmt_tailnet_connected)"
  echo '  peers'
  tailnet_peers
  echo '  latency'
  tailnet_ping mac 100.78.207.22
  tailnet_ping phone 100.88.249.22
else
  echo "  tailscale missing"
fi
