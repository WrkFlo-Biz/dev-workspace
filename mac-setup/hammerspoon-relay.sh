#!/usr/bin/env bash
# hammerspoon-relay.sh — keep the Tailscale-facing Hammerspoon relay alive.
set -euo pipefail

TS_IP=$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  echo "[hammerspoon-relay] tailscale not up" >&2
  exit 1
fi

exec /opt/homebrew/bin/socat \
  "TCP-LISTEN:9223,bind=$TS_IP,fork,reuseaddr" \
  "TCP:127.0.0.1:9223"
