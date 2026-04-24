#!/usr/bin/env bash
# chrome-cdp-relay.sh — keep Chrome DevTools Protocol bridged to Tailscale IP.
# LaunchAgent: com.wrkflo.chrome-cdp-relay (KeepAlive)

set -euo pipefail

TS_IP=$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  echo "Tailscale not up, exiting" >&2
  exit 1
fi

PORT=9222
SOCAT=/opt/homebrew/bin/socat
CHROME_PROFILE="$HOME/chrome-remote-profile"

if ! pgrep -f "Chrome.*remote-debugging-port" >/dev/null; then
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    --remote-debugging-port=$PORT \
    --user-data-dir="$CHROME_PROFILE" \
    --no-first-run --headless=new &
  sleep 2
fi

pkill -f "socat .*:$PORT" 2>/dev/null || true
sleep 0.3

exec "$SOCAT" \
  "TCP-LISTEN:$PORT,bind=$TS_IP,fork,reuseaddr" \
  "TCP:127.0.0.1:$PORT"
