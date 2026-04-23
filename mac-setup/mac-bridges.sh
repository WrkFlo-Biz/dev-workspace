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
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log() { printf '\033[1;34m[mac-bridges]\033[0m %s\n' "$*"; }
post_ok() {
  curl -fsS --max-time 2 -X POST "$1" \
    -H 'Content-Type: application/json' \
    -d '{}' >/dev/null 2>&1
}
get_ok() { curl -fsS --max-time 2 "$1" >/dev/null 2>&1; }
bridge_port() {
  local port=$1
  local label=$2
  pkill -f "socat .*:$port" 2>/dev/null || true
  log "bridging $TS_IP:$port → 127.0.0.1:$port ($label)"
  nohup "$SOCAT" \
    "TCP-LISTEN:$port,bind=$TS_IP,fork,reuseaddr" \
    "TCP:127.0.0.1:$port" \
    </dev/null >"/tmp/socat-${port}.log" 2>&1 &
  disown
}

TAILSCALE_BIN=$(command -v tailscale || true)
SOCAT=$(command -v socat || true)

if [ -z "$TAILSCALE_BIN" ]; then
  log "tailscale CLI missing; install it before starting bridges"
  exit 1
fi
if [ -z "$SOCAT" ]; then
  log "socat missing; install it with brew install socat"
  exit 1
fi

TS_IP=$("$TAILSCALE_BIN" ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  log "Tailscale not up; aborting"
  exit 1
fi

# ----- Chrome (9222) -----
if get_ok "http://127.0.0.1:9222/json/version"; then
  log "Chrome CDP already running on localhost:9222"
else
  bash "$(dirname "$0")/chrome-cdp.sh" || log "chrome-cdp.sh exited non-zero"
fi

if get_ok "http://127.0.0.1:9222/json/version"; then
  if get_ok "http://$TS_IP:9222/json/version"; then
    log "Chrome CDP bridge already running on $TS_IP:9222"
  else
    bridge_port 9222 "Chrome CDP"
  fi
fi

# ----- Hammerspoon (9223) -----
if post_ok "http://127.0.0.1:9223/apps"; then
  log "Hammerspoon HTTP API already running on localhost:9223"
elif [ -d "/Applications/Hammerspoon.app" ] || [ -d "$HOME/Applications/Hammerspoon.app" ]; then
  if ! pgrep -x Hammerspoon >/dev/null; then
    log "launching Hammerspoon"
    open -g -a Hammerspoon
  else
    log "waiting for Hammerspoon HTTP API on localhost:9223"
  fi
  for i in $(seq 1 10); do
    sleep 0.5
    post_ok "http://127.0.0.1:9223/apps" && break
  done
else
  log "Hammerspoon.app not found; skipping 9223 bridge"
fi

if post_ok "http://127.0.0.1:9223/apps"; then
  if post_ok "http://$TS_IP:9223/apps"; then
    log "Hammerspoon bridge already running on $TS_IP:9223"
  else
    bridge_port 9223 "Hammerspoon"
  fi
fi

sleep 0.5
log "bridges live:"
for port in 9222 9223; do
  if get_ok "http://$TS_IP:$port/json/version" || post_ok "http://$TS_IP:$port/apps"; then
    log "  $TS_IP:$port  ok"
  else
    log "  $TS_IP:$port  NOT RESPONDING"
  fi
done
