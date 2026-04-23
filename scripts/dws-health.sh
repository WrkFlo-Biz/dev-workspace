#!/usr/bin/env bash
set -u
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"; }
: "${MAC_GUI_URL:=http://100.78.207.22:9223}"
: "${MAC_CDP_URL:=http://100.78.207.22:9222}"

c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }
g(){ c 32 "$1"; }
y(){ c 33 "$1"; }
r(){ c 31 "$1"; }
h(){ c '1;36' "$1"; }
d(){ c 2 "$1"; }
sec(){ printf '\n%s\n' "$(h "== $1 ==")"; }
have(){ command -v "$1" >/dev/null 2>&1; }
http(){ curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null || printf 'ERR'; }
paint(){ case "$1" in 2??) g "$1" ;; 3??) y "$1" ;; *) r "$1" ;; esac; }
reach(){ case "$1" in 000|ERR) r "$1" ;; *) g "$1" ;; esac; }
ver(){ case "$1" in tmux) tmux -V 2>/dev/null ;; *) "$1" --version 2>/dev/null | sed -n '1p' ;; esac; }
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

[ -t 1 ] && clear 2>/dev/null || true
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
    set -- $(git -C "$d" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
    div="+$2/-$1"
  else
    div="no-upstream"
  fi
  dirty=$(git -C "$d" status --porcelain --ignore-submodules=dirty 2>/dev/null | sed -n '1p')
  printf '  %-30s %-14s %-12s %s\n' "$n" "$b" "$div" "$([ -n "$dirty" ] && y dirty || g clean)"
done

sec "Tooling"
printf '  foundry key  %s\n' "$([ -n "${AZURE_OPENAI_API_KEY:-}" ] && g loaded || r missing)"
printf '  codex        %s\n' "$(have codex && ver codex || r missing)"
printf '  claude       %s\n' "$(have claude && ver claude || r missing)"

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
printf '  orchestrator %s\n' "$(paint "$(http http://localhost:8787/healthz)")"
printf '  mac gui      %s  %s\n' "$(reach "$(http "$MAC_GUI_URL")")" "$MAC_GUI_URL"
printf '  mac cdp      %s  %s\n' "$(reach "$(http "$MAC_CDP_URL")")" "$MAC_CDP_URL"

sec "Tailnet"
if have tailscale; then
  printf '  connected    %s\n' "$(tailnet_connected && g yes || r no)"
  echo '  peers'
  tailnet_peers
  echo '  latency'
  tailnet_ping mac 100.78.207.22
  tailnet_ping phone 100.88.249.22
else
  echo "  tailscale missing"
fi
