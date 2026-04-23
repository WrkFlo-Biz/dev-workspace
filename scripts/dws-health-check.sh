#!/usr/bin/env bash
set -u
LOG=/tmp/dws-health.log
ALERT_LOG=/tmp/dws-health-alerts.log
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NOTIFY="$SCRIPT_DIR/dws-notify.sh"
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
check_pass=0 check_fail=0
alert(){ echo "$(ts) ALERT: $*" | tee -a "$ALERT_LOG"; [ -x "$NOTIFY" ] && "$NOTIFY" alert "$*" >/dev/null 2>&1 || true; check_fail=$((check_fail+1)); }
ok(){ check_pass=$((check_pass+1)); }

disk_pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
[ "$disk_pct" -lt 90 ] && ok || alert "disk at ${disk_pct}%"
mem_pct=$(free | awk 'NR==2{printf "%.0f", $3/$2*100}')
[ "$mem_pct" -lt 90 ] && ok || alert "memory at ${mem_pct}%"
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"; }
[ -n "${AZURE_OPENAI_API_KEY:-}" ] && ok || alert "Foundry API key not loaded"
tailscale status >/dev/null 2>&1 && ok || alert "Tailscale not connected"
MAC_IP="${MAC_GUI_URL:-http://100.78.207.22:9223}"
MAC_IP=$(echo "$MAC_IP" | sed 's|http://||;s|:.*||')
ping -c1 -W2 "$MAC_IP" >/dev/null 2>&1 && ok || alert "Mac unreachable at $MAC_IP"
for proj in global-sentinel wrkflo-voice-agents-ops openclaw-prod wrkflo-orchestrator dev-workspace; do
  [ -d "$HOME/projects/$proj/.git" ] && ok || alert "repo missing: $proj"
done
echo "$(ts) health: ${check_pass} ok, ${check_fail} fail" >> "$LOG"
[ "$check_fail" -eq 0 ] || exit 1
