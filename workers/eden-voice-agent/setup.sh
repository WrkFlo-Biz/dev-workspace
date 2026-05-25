#!/usr/bin/env bash
# setup.sh — install and start the Eden OS LiveKit voice agent.
# Run once on the dev VM after vm-setup.sh has run.
# Idempotent: safe to re-run for updates.

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$AGENT_DIR/.venv"
WRKFLO_CONFIG="$HOME/.config/wrkflo"
ENV_FILE="$WRKFLO_CONFIG/eden-voice-agent.env"
SYSTEMD_DIR="$HOME/.config/systemd/user"

log() { printf '\033[1;34m[eden-voice-agent]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[eden-voice-agent]\033[0m %s\n' "$*" >&2; }

# 1. Python venv
if [ ! -x "$VENV_DIR/bin/python" ]; then
  log "creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
log "installing/updating Python dependencies"
"$VENV_DIR/bin/pip" install -q --upgrade pip
"$VENV_DIR/bin/pip" install -q -r "$AGENT_DIR/requirements.txt"

# 2. Build the systemd EnvironmentFile from existing wrkflo config
mkdir -p "$WRKFLO_CONFIG"
{
  # LiveKit vars (strip `export ` prefix that bash sources use)
  if [ -f "$WRKFLO_CONFIG/livekit.env" ]; then
    grep -E '^(export )?LIVEKIT_' "$WRKFLO_CONFIG/livekit.env" \
      | sed 's/^export //'
  else
    warn "livekit.env not found — run apply-livekit-to-vm.sh first"
  fi

  # OpenRouter key (strip `export ` if present)
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY"
  else
    warn "OPENROUTER_API_KEY not set in environment — add it to $ENV_FILE manually"
  fi

  # ElevenLabs key from ~/.elevenlabs/api_key (raw key file)
  ELEVEN_KEY_FILE="$HOME/.elevenlabs/api_key"
  if [ -f "$ELEVEN_KEY_FILE" ]; then
    ELEVEN_KEY="$(cat "$ELEVEN_KEY_FILE" | tr -d '[:space:]')"
    printf 'ELEVENLABS_API_KEY=%s\n' "$ELEVEN_KEY"
  else
    warn "~/.elevenlabs/api_key not found — TTS will fall back to OpenRouter"
  fi

  # Deepgram key (optional — improves STT latency)
  if [ -n "${DEEPGRAM_API_KEY:-}" ]; then
    printf 'DEEPGRAM_API_KEY=%s\n' "$DEEPGRAM_API_KEY"
  fi

} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "wrote $ENV_FILE"

# 3. Install systemd user service
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/eden-voice-agent.service" <<SERVICE
[Unit]
Description=Eden OS LiveKit Voice Agent
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$AGENT_DIR
ExecStart=$VENV_DIR/bin/python $AGENT_DIR/agent.py start
EnvironmentFile=$ENV_FILE
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE

systemctl --user daemon-reload
systemctl --user enable eden-voice-agent.service

if systemctl --user is-active eden-voice-agent.service >/dev/null 2>&1; then
  log "restarting eden-voice-agent"
  systemctl --user restart eden-voice-agent.service
else
  log "starting eden-voice-agent"
  systemctl --user start eden-voice-agent.service
fi

log "done — check status with: systemctl --user status eden-voice-agent.service"
log "       and logs with:      journalctl --user -u eden-voice-agent.service -f"
