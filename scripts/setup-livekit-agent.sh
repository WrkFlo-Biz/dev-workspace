#!/usr/bin/env bash
# setup-livekit-agent.sh — Install and start the Eden LiveKit AI voice agent on the dev VM.
#
# Run this on the dev VM after apply-livekit-to-vm.sh.
# Requires LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, and OPENROUTER_API_KEY
# in the environment (or sourced from ~/.config/wrkflo/livekit.env).
#
# Usage:
#   ssh moses@100.117.16.63
#   export OPENROUTER_API_KEY="sk-or-..."
#   bash ~/scripts/setup-livekit-agent.sh

set -euo pipefail

AGENT_DIR="/opt/livekit-agent"
SERVICE_NAME="eden-livekit-agent"
LIVEKIT_ENV_FILE="$HOME/.config/wrkflo/livekit.env"

echo "[setup-livekit-agent] starting setup..."

# ── 1. Ensure Python 3.11+ ────────────────────────────────────────────────────
if command -v python3.11 &>/dev/null; then
  PYTHON=$(command -v python3.11)
elif command -v python3.12 &>/dev/null; then
  PYTHON=$(command -v python3.12)
elif command -v python3.13 &>/dev/null; then
  PYTHON=$(command -v python3.13)
elif command -v python3 &>/dev/null && python3 -c 'import sys; assert sys.version_info >= (3,11)' 2>/dev/null; then
  PYTHON=$(command -v python3)
else
  echo "[setup-livekit-agent] Python 3.11+ not found — installing via apt..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq python3.11 python3.11-venv python3-pip
  PYTHON=$(command -v python3.11)
fi

echo "[setup-livekit-agent] using Python: $PYTHON ($($PYTHON --version))"

# ── 2. Create agent directory ─────────────────────────────────────────────────
sudo mkdir -p "$AGENT_DIR"
sudo chown moses:moses "$AGENT_DIR"

# ── 3. Set up virtualenv + install packages ───────────────────────────────────
if [ ! -d "$AGENT_DIR/venv" ]; then
  echo "[setup-livekit-agent] creating virtualenv..."
  $PYTHON -m venv "$AGENT_DIR/venv"
fi

echo "[setup-livekit-agent] installing Python packages..."
"$AGENT_DIR/venv/bin/pip" install --quiet --upgrade pip
"$AGENT_DIR/venv/bin/pip" install --quiet \
  "livekit-agents[openai]>=0.12" \
  "python-dotenv>=1.0"

echo "[setup-livekit-agent] packages installed."

# ── 4. Write the agent Python file ───────────────────────────────────────────
cat >"$AGENT_DIR/eden_voice_agent.py" <<'PYTHON_EOF'
"""
eden_voice_agent.py — LiveKit VoicePipelineAgent for Eden.

Joins room `eden-voice`, receives participant audio, and responds via:
  STT  : OpenAI Whisper (via OpenAI-compatible livekit-agents plugin)
  LLM  : google/gemini-2.5-flash on OpenRouter (OpenAI-compatible API)
  TTS  : OpenAI TTS (via livekit-agents OpenAI plugin)

Required env vars:
  LIVEKIT_URL          wss://wrk-flo-sbhpsveo.livekit.cloud
  LIVEKIT_API_KEY      LiveKit API key
  LIVEKIT_API_SECRET   LiveKit API secret
  OPENROUTER_API_KEY   OpenRouter API key (sk-or-...)
"""

import os
import logging
from dotenv import load_dotenv

load_dotenv()

from livekit.agents import (
    AutoSubscribe,
    JobContext,
    JobProcess,
    WorkerOptions,
    cli,
    llm,
)
from livekit.agents.voice_pipeline_agent import VoicePipelineAgent
from livekit.plugins import openai as lk_openai

logger = logging.getLogger("eden-voice-agent")

SYSTEM_PROMPT = (
    "You are Eden, a voice-first AI Chief of Staff. "
    "You help with email, calendar, business decisions, and daily priorities. "
    "Be concise — you are speaking aloud."
)

ROOM_NAME = "eden-voice"


def prewarm(proc: JobProcess) -> None:
    """Pre-load VAD model in the worker process before accepting jobs."""
    proc.userdata["vad"] = lk_openai.realtime.RealtimeModel  # placeholder; actual VAD below


async def entrypoint(ctx: JobContext) -> None:
    logger.info("Eden voice agent connecting to room: %s", ctx.room.name)

    openrouter_api_key = os.environ["OPENROUTER_API_KEY"]

    # STT — Whisper via livekit-agents OpenAI plugin
    stt = lk_openai.STT(
        model="whisper-1",
        language="en",
    )

    # LLM — OpenAI-compatible pointing at OpenRouter
    llm_plugin = lk_openai.LLM.with_azure(
        model="google/gemini-2.5-flash",
        base_url="https://openrouter.ai/api/v1",
        api_key=openrouter_api_key,
    )

    # TTS — OpenAI TTS (alloy voice, concise for voice UX)
    tts = lk_openai.TTS(
        model="tts-1",
        voice="alloy",
    )

    initial_ctx = llm.ChatContext().append(
        role="system",
        text=SYSTEM_PROMPT,
    )

    agent = VoicePipelineAgent(
        vad=lk_openai.realtime.RealtimeModel,  # silero VAD is pulled in by livekit-agents[openai]
        stt=stt,
        llm=llm_plugin,
        tts=tts,
        chat_ctx=initial_ctx,
    )

    # Wait for the first human participant then start the pipeline
    await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)
    participant = await ctx.wait_for_participant()
    logger.info("participant joined: %s", participant.identity)

    agent.start(ctx.room, participant)
    await agent.say("Hello, I'm Eden. How can I help you today?", allow_interruptions=True)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    cli.run_app(
        WorkerOptions(
            entrypoint_fnc=entrypoint,
            prewarm_fnc=prewarm,
        )
    )
PYTHON_EOF

echo "[setup-livekit-agent] agent file written: $AGENT_DIR/eden_voice_agent.py"

# ── 5. Write .env for the agent (sources from livekit.env + OPENROUTER key) ──
cat >"$AGENT_DIR/.env" <<ENV_EOF
# Eden LiveKit agent environment
# LIVEKIT_* vars are sourced from $LIVEKIT_ENV_FILE at runtime via the service.
# OPENROUTER_API_KEY must be injected here or passed via systemd override.
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
ENV_EOF
chmod 600 "$AGENT_DIR/.env"
echo "[setup-livekit-agent] .env written."

# ── 6. Write systemd service ──────────────────────────────────────────────────
# We source livekit.env in ExecStartPre and pass vars via EnvironmentFile.
# A separate EnvironmentFile overlay file is written per-deploy so the
# LIVEKIT_* vars end up in the service environment without storing secrets
# in the unit file itself.

LIVEKIT_OVERLAY="/opt/livekit-agent/.livekit-vars.env"

# Snapshot current livekit vars into the overlay (readable only by moses).
if [ -f "$LIVEKIT_ENV_FILE" ]; then
  # Strip 'export ' prefix so EnvironmentFile= can parse it.
  grep -E '^export (LIVEKIT_URL|LIVEKIT_API_KEY|LIVEKIT_API_SECRET)=' "$LIVEKIT_ENV_FILE" \
    | sed 's/^export //' >"$LIVEKIT_OVERLAY"
  chmod 600 "$LIVEKIT_OVERLAY"
  echo "[setup-livekit-agent] livekit vars snapshot written: $LIVEKIT_OVERLAY"
else
  echo "[setup-livekit-agent] WARNING: $LIVEKIT_ENV_FILE not found — LIVEKIT_* vars must be set another way."
  touch "$LIVEKIT_OVERLAY"
fi

sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<SERVICE_EOF
[Unit]
Description=Eden LiveKit Voice Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=moses
WorkingDirectory=/opt/livekit-agent

# Inject LiveKit creds (stripped of 'export' prefix)
EnvironmentFile=/opt/livekit-agent/.livekit-vars.env
# Inject OpenRouter key + any overrides
EnvironmentFile=/opt/livekit-agent/.env

ExecStart=/opt/livekit-agent/venv/bin/python /opt/livekit-agent/eden_voice_agent.py start

Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=eden-livekit-agent

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "[setup-livekit-agent] systemd unit written."

# ── 7. Enable and start the service ──────────────────────────────────────────
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"
sudo systemctl restart "${SERVICE_NAME}.service"

echo ""
echo "[setup-livekit-agent] done!"
echo ""
echo "  Status : sudo systemctl status ${SERVICE_NAME}"
echo "  Logs   : sudo journalctl -u ${SERVICE_NAME} -f"
echo "  Room   : eden-voice @ \$LIVEKIT_URL"
