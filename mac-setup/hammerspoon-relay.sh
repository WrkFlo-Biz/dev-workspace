#!/usr/bin/env bash
# hammerspoon-relay.sh — keep Hammerspoon HTTP API bridged to Tailscale IP.
# LaunchAgent: com.wrkflo.hammerspoon-relay (KeepAlive)

set -euo pipefail

TS_IP=$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  echo "Tailscale not up, exiting" >&2
  exit 1
fi

PORT=9223
SOCAT=/opt/homebrew/bin/socat

if ! pgrep -x Hammerspoon >/dev/null; then
  open -g -a Hammerspoon
  for i in $(seq 1 10); do
    sleep 0.5
    curl -fsS -X POST "http://127.0.0.1:$PORT/apps" \
      -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 && break
  done
fi

pkill -f "socat .*:$PORT" 2>/dev/null || true
sleep 0.3

exec "$SOCAT" \
  "TCP-LISTEN:$PORT,bind=$TS_IP,fork,reuseaddr" \
  "TCP:127.0.0.1:$PORT"
