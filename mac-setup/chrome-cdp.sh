#!/usr/bin/env bash
# chrome-cdp.sh — start Chrome with CDP (DevTools Protocol) on the Mac,
# bind it to a dedicated automation profile, and expose the port on the
# Tailscale interface so the dev-workspace VM (or codex on it) can drive it.
#
# Profile dir:  ~/chrome-remote-profile      (separate from main Chrome)
# CDP port:     9222  (localhost, bridged to Tailscale by socat)
# Reachable at: http://100.78.207.22:9222     (and mosess-macbook-air-3:9222)
#
# Re-run anytime: it kills prior instances/socat forwards before starting.

set -euo pipefail

PROFILE="$HOME/chrome-remote-profile"
CDP_PORT=9222
TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

log() { printf '\033[1;34m[chrome-cdp]\033[0m %s\n' "$*"; }

# Stop any prior socat forward and any chrome started against this profile.
pkill -f "socat .*:$CDP_PORT" 2>/dev/null || true
pkill -f "Google Chrome.*remote-debugging-port" 2>/dev/null || true
sleep 1

log "launching Chrome with remote debugging (profile: $PROFILE)"
# nohup + setsid-equivalent so the process survives this script exiting.
nohup "$CHROME" \
  --remote-debugging-port=$CDP_PORT \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --disable-features=ChromeWhatsNewUI \
  </dev/null >/tmp/chrome-cdp.log 2>&1 &
disown

# Wait until CDP is up on localhost
for i in $(seq 1 20); do
  sleep 0.5
  if curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
    break
  fi
done
curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null || {
  echo "CDP did not come up in time — check /tmp/chrome-cdp.log"; exit 1;
}

if [ -n "$TS_IP" ]; then
  log "bridging $TS_IP:$CDP_PORT → 127.0.0.1:$CDP_PORT (socat)"
  nohup /opt/homebrew/bin/socat \
    "TCP-LISTEN:$CDP_PORT,bind=$TS_IP,fork,reuseaddr" \
    "TCP:127.0.0.1:$CDP_PORT" \
    </dev/null >/tmp/socat-cdp.log 2>&1 &
  disown
  sleep 0.5
  log "verify from this Mac: curl http://$TS_IP:$CDP_PORT/json/version"
else
  log "Tailscale not up — CDP reachable only via localhost:$CDP_PORT"
fi

log "done. From the VM:"
log "  curl http://100.78.207.22:$CDP_PORT/json/version"
log "  (WebSocket URL to attach puppeteer/playwright is in the JSON response)"
