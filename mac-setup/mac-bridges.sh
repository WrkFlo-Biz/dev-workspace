#!/usr/bin/env bash
# mac-bridges.sh — start (or restart) ALL mac-side remote bridges so codex on
# the dev-workspace VM can drive this Mac over Tailscale.
#
# Bridges:
#   9222  →  Chrome DevTools Protocol  (for puppeteer / playwright)
#   9223  →  Hammerspoon HTTP API      (for GUI actions, osascript, keystrokes)
#
# Both bind Chrome/Hammerspoon on 127.0.0.1 and use socat to expose them on
# the Tailscale interface. Re-runnable — kills prior instances first.

set -euo pipefail
log() { printf '\033[1;34m[mac-bridges]\033[0m %s\n' "$*"; }

TS_IP=$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  log "Tailscale not up; aborting"
  exit 1
fi

SOCAT=/opt/homebrew/bin/socat

# ----- Chrome (9222) -----
bash "$(dirname "$0")/chrome-cdp.sh" || log "chrome-cdp.sh exited non-zero"

# ----- Hammerspoon (9223) -----
if ! pgrep -x Hammerspoon >/dev/null; then
  log "launching Hammerspoon"
  open -g -a Hammerspoon
  for i in $(seq 1 10); do
    sleep 0.5
    curl -fsS -X POST "http://127.0.0.1:9223/apps" \
      -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 && break
  done
fi

pkill -f "socat .*:9223" 2>/dev/null || true
log "bridging $TS_IP:9223 → 127.0.0.1:9223 (Hammerspoon)"
nohup "$SOCAT" \
  "TCP-LISTEN:9223,bind=$TS_IP,fork,reuseaddr" \
  "TCP:127.0.0.1:9223" \
  </dev/null >/tmp/socat-hs.log 2>&1 &
disown

sleep 0.5
log "bridges live:"
for port in 9222 9223; do
  if curl -fsS --max-time 2 "http://$TS_IP:$port/json/version" >/dev/null 2>&1 \
      || curl -fsS --max-time 2 -X POST "http://$TS_IP:$port/apps" \
         -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1; then
    log "  $TS_IP:$port  ok"
  else
    log "  $TS_IP:$port  NOT RESPONDING"
  fi
done
