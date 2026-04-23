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
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROFILE="$HOME/chrome-remote-profile"
CDP_PORT=9222
CHROME_APP='/Applications/Google Chrome.app'
TAILSCALE_BIN=$(command -v tailscale || true)
SOCAT=$(command -v socat || true)
TS_IP=$([ -n "$TAILSCALE_BIN" ] && "$TAILSCALE_BIN" ip -4 2>/dev/null | head -1 || true)

log() { printf '\033[1;34m[chrome-cdp]\033[0m %s\n' "$*"; }

if [ ! -d "$CHROME_APP" ]; then
  log "Google Chrome.app not found; cannot start CDP bridge"
  exit 1
fi

# Stop any prior socat forward and any chrome started against this profile.
pkill -f "socat .*:$CDP_PORT" 2>/dev/null || true
pkill -f "Google Chrome.*remote-debugging-port" 2>/dev/null || true
sleep 1

log "launching Chrome with remote debugging (profile: $PROFILE)"
# Launch via LaunchServices instead of backgrounding the app binary directly.
# That keeps the dedicated Chrome instance alive more reliably on macOS.
open -na "$CHROME_APP" --args \
  --remote-debugging-port=$CDP_PORT \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --disable-features=ChromeWhatsNewUI \
  about:blank

# Wait until CDP is up on localhost
for i in $(seq 1 20); do
  sleep 0.5
  if curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
    break
  fi
done
curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null || {
  echo "CDP did not come up in time — Chrome may still be blocked by an existing profile lock or launch failure"; exit 1;
}

if [ -n "$TS_IP" ]; then
  if [ -z "$SOCAT" ]; then
    log "socat missing; CDP is reachable only via localhost:$CDP_PORT"
    exit 0
  fi
  log "bridging $TS_IP:$CDP_PORT → 127.0.0.1:$CDP_PORT (socat)"
  nohup "$SOCAT" \
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
