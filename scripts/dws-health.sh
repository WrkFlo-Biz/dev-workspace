#!/usr/bin/env bash
set -u
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"; }
: "${MAC_TAILNET_IP:=100.78.207.22}"
: "${PHONE_TAILNET_IP:=100.88.249.22}"
: "${GATEWAY_TAILNET_IP:=100.126.194.98}"
: "${MAC_GUI_URL:=http://${MAC_TAILNET_IP}:9223}"
: "${MAC_CDP_URL:=http://${MAC_TAILNET_IP}:9222}"
ORCHESTRATOR_HEALTH_URL="${DWS_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"
SSH_HARDENING_CONF="${DWS_SSH_HARDENING_CONF:-/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf}"

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
http_post_json(){
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -X POST "$1" -H 'Content-Type: application/json' -d '{}' 2>/dev/null) || { printf 'ERR'; return; }
  printf '%s' "$code"
}
paint(){ case "$1" in 2??) g "$1" ;; 3??) y "$1" ;; *) r "$1" ;; esac; }
reach(){ paint "$1"; }
mac_gui_health_url(){ printf '%s/apps' "${MAC_GUI_URL%/}"; }
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
unit_name(){ case "$1" in *.service) printf '%s' "$1" ;; *) printf '%s.service' "$1" ;; esac; }
user_unit_state(){
  local unit state sub
  unit=$(unit_name "$1")
  if ! have systemctl; then
    printf 'missing'
    return
  fi
  state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  state=$(printf '%s\n' "$state" | sed -n '1p')
  case "$state" in
    active)
      sub=$(systemctl --user show "$unit" --property=SubState --value 2>/dev/null | sed -n '1p')
      [ -n "$sub" ] && [ "$sub" != "$state" ] && printf '%s (%s)' "$state" "$sub" || printf '%s' "$state"
      ;;
    '') printf 'unknown' ;;
    *) printf '%s' "$state" ;;
  esac
}
fmt_user_unit_state(){ case "$1" in active*) g "$1" ;; activating*|reloading*) y "$1" ;; *) r "$1" ;; esac; }
user_unit_ok(){ case "$1" in active*) return 0 ;; *) return 1 ;; esac; }
ssh_hardening_values(){
  [ -r "$SSH_HARDENING_CONF" ] || return 1
  awk '
    tolower($1) == "passwordauthentication" { pa = tolower($2) }
    tolower($1) == "permitrootlogin" { pr = tolower($2) }
    tolower($1) == "clientaliveinterval" { ca = $2 }
    END { printf "%s|%s|%s\n", pa, pr, ca }
  ' "$SSH_HARDENING_CONF" 2>/dev/null
}
ssh_hardening_state(){
  local vals pa pr ca
  vals=$(ssh_hardening_values) || { printf 'missing'; return; }
  IFS='|' read -r pa pr ca <<<"$vals"
  if [ "$pa" = "no" ] && [ "$pr" = "no" ] && [ "$ca" = "30" ]; then
    printf 'ok'
  else
    printf 'drift'
  fi
}
fmt_ssh_hardening_state(){ case "$1" in ok) g "$1" ;; drift) y "$1" ;; *) r "$1" ;; esac; }
ssh_hardening_ok(){ [ "$1" = "ok" ]; }
ssh_hardening_detail(){
  local vals pa pr ca
  vals=$(ssh_hardening_values) || { printf '%s' "$SSH_HARDENING_CONF"; return; }
  IFS='|' read -r pa pr ca <<<"$vals"
  printf '%s (pass=%s root=%s alive=%s)' \
    "$SSH_HARDENING_CONF" "${pa:-unset}" "${pr:-unset}" "${ca:-unset}"
}
firewall_status(){
  local out
  if have ufw; then
    out=$(ufw status 2>&1 || true)
    case "$out" in
      *"You need to be root"*) have sudo && out=$(sudo -n ufw status 2>&1 || true) ;;
    esac
    if printf '%s\n' "$out" | grep -q '^Status: active'; then
      printf 'ufw|active|\n'
      return
    fi
    if printf '%s\n' "$out" | grep -q '^Status: inactive'; then
      printf 'ufw|inactive|no rules loaded\n'
      return
    fi
    if printf '%s\n' "$out" | grep -q 'You need to be root'; then
      printf 'ufw|unreadable|needs root\n'
      return
    fi
    printf 'ufw|unknown|%s\n' "$(printf '%s\n' "$out" | sed -n '1p')"
    return
  fi
  if have firewall-cmd; then
    out=$(firewall-cmd --state 2>&1 || true)
    [ "$out" = "running" ] && printf 'firewalld|running|\n' || printf 'firewalld|%s|\n' "${out:-unknown}"
    return
  fi
  if have nft; then
    out=$(nft list ruleset 2>/dev/null || { have sudo && sudo -n nft list ruleset 2>/dev/null; } || true)
    [ -n "$out" ] && printf 'nftables|present|\n' || printf 'nftables|unreadable|needs root\n'
    return
  fi
  if have iptables; then
    out=$(iptables -S 2>/dev/null || { have sudo && sudo -n iptables -S 2>/dev/null; } || true)
    [ -n "$out" ] && printf 'iptables|present|\n' || printf 'iptables|unreadable|needs root\n'
    return
  fi
  printf 'none|missing|no supported firewall tool found\n'
}
fmt_firewall_state(){ case "$1" in active|running|present) g "$1" ;; inactive|unreadable|unknown) y "$1" ;; *) r "$1" ;; esac; }
firewall_ok(){ case "$1" in active|running|present) return 0 ;; *) return 1 ;; esac; }
tailnet_connected(){ have tailscale && tailscale status >/dev/null 2>&1; }
tailnet_ping_result(){
  local ip="$1" out lat
  if ! have tailscale; then
    printf 'missing|\n'
    return
  fi
  out=$(tailscale ping -c 1 "$ip" 2>/dev/null | sed -n '1p')
  lat=$(printf '%s\n' "$out" | sed -n 's/.* in \([^ ]*\)$/\1/p')
  [ -n "$lat" ] && printf 'reachable|%s\n' "$lat" || printf 'unreachable|\n'
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
    task_state=$(user_unit_state dws-task-monitor)
    task_ok=false; user_unit_ok "$task_state" && task_ok=true
    sessions_state=$(user_unit_state dws-sessions-init)
    sessions_ok=false; user_unit_ok "$sessions_state" && sessions_ok=true
    ssh_state=$(ssh_hardening_state)
    ssh_ok=false; ssh_hardening_ok "$ssh_state" && ssh_ok=true
    IFS='|' read -r fw_backend fw_state fw_detail <<<"$(firewall_status)"
    fw_ok=false; firewall_ok "$fw_state" && fw_ok=true
    tailnet_ok=false; tailnet_connected && tailnet_ok=true
    IFS='|' read -r mac_state mac_lat <<<"$(tailnet_ping_result "$MAC_TAILNET_IP")"
    mac_ok=false; [ "$mac_state" = "reachable" ] && mac_ok=true
    IFS='|' read -r phone_state phone_lat <<<"$(tailnet_ping_result "$PHONE_TAILNET_IP")"
    phone_ok=false; [ "$phone_state" = "reachable" ] && phone_ok=true
    IFS='|' read -r gateway_state gateway_lat <<<"$(tailnet_ping_result "$GATEWAY_TAILNET_IP")"
    gateway_ok=false; [ "$gateway_state" = "reachable" ] && gateway_ok=true
    printf '{\n'
    printf '  "system":{"hostname":"%s","uptime":"%s","disk":"%s","memory":"%s"},\n' \
      "$(jesc "$(hostname -s 2>/dev/null || hostname)")" "$(jesc "$(uptime -p 2>/dev/null || uptime)")" \
      "$(jesc "$(df -h / | awk 'NR == 2 { print $3 "/" $2 " (" $5 " used)" }')")" "$(jesc "$(free -h | awk 'NR == 2 { print $3 "/" $2 " used" }')")"
    printf '  "tools":{"codex_version":"%s","claude_version":"%s","gh_auth":%s,"foundry_key_loaded":%s},\n' \
      "$(jesc "$(have codex && ver codex || echo missing)")" "$(jesc "$(have claude && ver claude || echo missing)")" "$gh_ok" "$([ -n "${AZURE_OPENAI_API_KEY:-}" ] && echo true || echo false)"
    printf '  "services":{"orchestrator_api":{"url":"%s","http_code":"%s","reachable":%s},"dws_task_monitor":{"state":"%s","healthy":%s},"dws_sessions_init":{"state":"%s","healthy":%s}},\n' \
      "$(jesc "$ORCHESTRATOR_HEALTH_URL")" "$(jesc "$orch_code")" "$orch_ok" "$(jesc "$task_state")" "$task_ok" "$(jesc "$sessions_state")" "$sessions_ok"
    printf '  "security":{"ssh_hardening":{"path":"%s","state":"%s","healthy":%s},"firewall":{"backend":"%s","state":"%s","detail":"%s","healthy":%s}},\n' \
      "$(jesc "$SSH_HARDENING_CONF")" "$(jesc "$ssh_state")" "$ssh_ok" "$(jesc "$fw_backend")" "$(jesc "$fw_state")" "$(jesc "$fw_detail")" "$fw_ok"
    printf '  "tailnet":{"connected":%s,"peers":{"mac":{"ip":"%s","state":"%s","latency":"%s","reachable":%s},"phone":{"ip":"%s","state":"%s","latency":"%s","reachable":%s},"gateway":{"ip":"%s","state":"%s","latency":"%s","reachable":%s}}},\n' \
      "$tailnet_ok" \
      "$(jesc "$MAC_TAILNET_IP")" "$(jesc "$mac_state")" "$(jesc "$mac_lat")" "$mac_ok" \
      "$(jesc "$PHONE_TAILNET_IP")" "$(jesc "$phone_state")" "$(jesc "$phone_lat")" "$phone_ok" \
      "$(jesc "$GATEWAY_TAILNET_IP")" "$(jesc "$gateway_state")" "$(jesc "$gateway_lat")" "$gateway_ok"
    printf '  "sessions":'; json_sessions; printf ',\n'
    printf '  "projects":'; json_projects; printf '\n'
    printf '}\n'
    exit 0
    ;;
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
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
  local label="$1" ip="$2" state lat
  IFS='|' read -r state lat <<<"$(tailnet_ping_result "$ip")"
  case "$state" in
    reachable) printf '  %-12s %s  %s\n' "$label" "$(g "$lat")" "$ip" ;;
    *) printf '  %-12s %s  %s\n' "$label" "$(r unreachable)" "$ip" ;;
  esac
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
printf '  task monitor %s\n' "$(fmt_user_unit_state "$(user_unit_state dws-task-monitor)")"
printf '  sessions init %s\n' "$(fmt_user_unit_state "$(user_unit_state dws-sessions-init)")"
printf '  orchestrator %s  %s\n' "$(paint "$(http "$ORCHESTRATOR_HEALTH_URL")")" "$ORCHESTRATOR_HEALTH_URL"
printf '  mac gui      %s  %s\n' "$(reach "$(http_post_json "$(mac_gui_health_url)")")" "$(mac_gui_health_url)"
printf '  mac cdp      %s  %s\n' "$(reach "$(http "$MAC_CDP_URL")")" "$MAC_CDP_URL"

sec "Security"
printf '  ssh config   %s  %s\n' "$(fmt_ssh_hardening_state "$(ssh_hardening_state)")" "$(ssh_hardening_detail)"
IFS='|' read -r fw_backend fw_state fw_detail <<<"$(firewall_status)"
fw_label="$fw_backend"; [ -n "$fw_detail" ] && fw_label="$fw_label ($fw_detail)"
printf '  firewall     %s  %s\n' "$(fmt_firewall_state "$fw_state")" "$fw_label"

sec "Tailnet"
if have tailscale; then
  printf '  connected    %s\n' "$(fmt_tailnet_connected)"
  echo '  peers'
  tailnet_peers
  echo '  connectivity'
  tailnet_ping mac "$MAC_TAILNET_IP"
  tailnet_ping phone "$PHONE_TAILNET_IP"
  tailnet_ping gateway "$GATEWAY_TAILNET_IP"
else
  echo "  tailscale missing"
fi
