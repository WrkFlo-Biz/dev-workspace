#!/usr/bin/env python3
"""
Eden OS LiveKit Voice Agent.

Listens in the `eden-voice` LiveKit room and provides the same Chief of Staff
persona as the ElevenLabs ConvAI agent, but over LiveKit WebRTC transport.
Calls the local Eden API server (port 5188) for all governed operations.

Required env vars:
  LIVEKIT_URL          wss://wrk-flo-sbhpsveo.livekit.cloud
  LIVEKIT_API_KEY      APIk...
  LIVEKIT_API_SECRET   0fON...
  OPENROUTER_API_KEY   sk-or-v1-...
  ELEVENLABS_API_KEY   (optional — falls back to OpenRouter TTS)
  DEEPGRAM_API_KEY     (optional — falls back to OpenAI-compatible STT)
  EDEN_API_BASE        http://127.0.0.1:5188 (default)
  ELEVENLABS_VOICE_ID  (optional — defaults to Alice)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Annotated

import httpx
from dotenv import load_dotenv
from livekit.agents import (
    Agent,
    AgentSession,
    AutoSubscribe,
    JobContext,
    JobProcess,
    WorkerOptions,
    cli,
    function_tool,
)
from livekit.plugins import silero

load_dotenv(dotenv_path=os.path.expanduser("~/.config/wrkflo/eden-voice-agent.env"))
load_dotenv(dotenv_path=os.path.expanduser("~/.config/wrkflo/livekit.env"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s [eden-agent] %(message)s")
logger = logging.getLogger("eden-voice-agent")

EDEN_API_BASE = os.getenv("EDEN_API_BASE", "http://127.0.0.1:5188")
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "")
DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY", "")
ELEVENLABS_VOICE_ID = os.getenv("ELEVENLABS_VOICE_ID", "Xb7hH8MSUJpSbSDYk0k2")

SYSTEM_PROMPT = """\
You are Eden, a voice-first AI Chief of Staff OS. You help the operator manage their
business and personal operations. You run on the Wrk.Flo platform.

Rules:
- Be concise in speech. One or two sentences per response unless detail is specifically requested.
- When the user says goodbye, stop, hang up, or end call — say a brief farewell and stop speaking.
- For external writes (send email, post, create calendar event) — propose first, wait for confirmation, then execute.
- For lookups (emails, calendar, status) — run immediately, report the result.
- All times in Central Time (CST/CDT) unless the user specifies otherwise.
- Azure services are paused due to billing. Use local routes and Composio connectors.
- Do not mention tool names, API calls, or internal system details in speech.
- If a tool call fails, say "I couldn't reach that right now" and move on.
"""


# ---------------------------------------------------------------------------
# Tools — thin HTTP wrappers over the Eden API server
# ---------------------------------------------------------------------------

@function_tool()
async def get_daily_brief() -> str:
    """Get the daily operating brief including pending approvals and connector status."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await client.get(f"{EDEN_API_BASE}/api/os/brief")
            resp.raise_for_status()
        except Exception as exc:
            logger.warning("brief fetch failed: %s", exc)
            return "Daily brief unavailable — Eden server not responding."
        brief = resp.json().get("brief", {})
        parts: list[str] = []
        if pending := brief.get("pendingActions", 0):
            parts.append(f"{pending} pending approval{'s' if pending != 1 else ''}")
        if summary := brief.get("summary"):
            parts.append(summary)
        connectors = brief.get("connectorStatus", [])
        if connectors:
            ready = sum(1 for c in connectors if "ready" in str(c.get("health", "")))
            parts.append(f"{ready} of {len(connectors)} connectors ready")
        return ". ".join(parts) if parts else "All clear. No pending items."


@function_tool()
async def get_pending_actions() -> str:
    """List actions currently waiting for the operator's approval."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await client.get(f"{EDEN_API_BASE}/api/actions?status=pending_approval&limit=5")
            resp.raise_for_status()
        except Exception as exc:
            logger.warning("actions fetch failed: %s", exc)
            return "Could not fetch the approval queue."
        actions = resp.json().get("actions", [])
        if not actions:
            return "No pending approvals."
        items = [
            f"{a.get('action', '?').replace('_', ' ')}: {(a.get('summary') or a.get('id', '?'))[:50]}"
            for a in actions[:5]
        ]
        return f"{len(actions)} waiting: " + "; ".join(items)


@function_tool()
async def propose_action(
    action: Annotated[str, "Action type: gmail_send_email, calendar_create_event, google_docs_create_document, linkedin_create_post, slack_send_message, composio_execute"],
    summary: Annotated[str, "Plain-language description of exactly what will happen"],
    fields: Annotated[str, "JSON object with action-specific fields, e.g. {\"recipient_email\":\"x@y.com\",\"subject\":\"Hi\",\"body\":\"...\"}"],
) -> str:
    """Stage a governed action for operator approval. Always call this before external writes."""
    try:
        extra = json.loads(fields)
    except Exception:
        extra = {}
    payload = {"action": action, "summary": summary, "executeNow": False, **extra}
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await client.post(f"{EDEN_API_BASE}/api/actions/propose", json=payload)
            resp.raise_for_status()
        except Exception as exc:
            logger.warning("propose failed: %s", exc)
            return "Failed to stage the action."
        data = resp.json()
        action_id = data.get("action", {}).get("id", "unknown")
        return f"Staged for approval (id {action_id}): {summary}. Tell me to proceed when ready."


@function_tool()
async def execute_latest_action() -> str:
    """Execute the most recently staged action after the operator confirms."""
    async with httpx.AsyncClient(timeout=20.0) as client:
        try:
            resp = await client.post(
                f"{EDEN_API_BASE}/api/actions/execute",
                json={"approvalConfirmed": True},
            )
            resp.raise_for_status()
        except Exception as exc:
            logger.warning("execute failed: %s", exc)
            return "Execution failed — Eden server error."
        data = resp.json()
        if data.get("ok"):
            return data.get("message", "Done.")
        return f"Could not execute: {data.get('error', 'unknown error')}"


@function_tool()
async def check_connectors() -> str:
    """Check which integrations and connectors are currently ready."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await client.get(f"{EDEN_API_BASE}/api/capabilities")
            resp.raise_for_status()
        except Exception as exc:
            logger.warning("capabilities fetch failed: %s", exc)
            return "Connector status unavailable."
        caps = resp.json().get("capabilities", {})
        ready, missing = [], []
        for name, info in caps.items():
            if isinstance(info, dict):
                (ready if info.get("ok") else missing).append(name)
        parts = []
        if ready:
            parts.append(f"Ready: {', '.join(ready[:5])}")
        if missing:
            parts.append(f"Not configured: {', '.join(missing[:4])}")
        return ". ".join(parts) if parts else "No connector data returned."


@function_tool()
async def search_knowledge(
    query: Annotated[str, "What to search for in the knowledge base"],
) -> str:
    """Search the local knowledge base for documents, SOPs, or context."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await client.post(
                f"{EDEN_API_BASE}/api/knowledge/search",
                json={"query": query, "limit": 3},
            )
            resp.raise_for_status()
        except Exception as exc:
            logger.warning("knowledge search failed: %s", exc)
            return "Knowledge search unavailable."
        results = resp.json().get("results", [])
        if not results:
            return f"Nothing found for '{query}'."
        items = [
            f"{r.get('title', 'Untitled')}: {(r.get('snippet') or r.get('content', ''))[:80]}"
            for r in results[:3]
        ]
        return " | ".join(items)


TOOLS = [
    get_daily_brief,
    get_pending_actions,
    propose_action,
    execute_latest_action,
    check_connectors,
    search_knowledge,
]


# ---------------------------------------------------------------------------
# Agent lifecycle
# ---------------------------------------------------------------------------

def prewarm(proc: JobProcess) -> None:
    """Load VAD model once per worker process, shared across sessions."""
    proc.userdata["vad"] = silero.VAD.load()


async def entrypoint(ctx: JobContext) -> None:
    from livekit.plugins import openai as lk_openai

    logger.info("connecting to room: %s", ctx.room.name)
    await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)

    # STT: Deepgram preferred (lower latency); falls back to OpenAI Whisper via OpenRouter
    if DEEPGRAM_API_KEY:
        from livekit.plugins import deepgram as lk_deepgram
        stt = lk_deepgram.STT(api_key=DEEPGRAM_API_KEY, language="en-US")
        logger.info("STT: Deepgram")
    else:
        stt = lk_openai.STT(
            base_url="https://openrouter.ai/api/v1",
            api_key=OPENROUTER_API_KEY,
            model="openai/whisper-large-v3",
        )
        logger.info("STT: OpenRouter/Whisper (no DEEPGRAM_API_KEY set)")

    # TTS: ElevenLabs preferred; falls back to OpenRouter TTS
    if ELEVENLABS_API_KEY:
        from livekit.plugins import elevenlabs as lk_elevenlabs
        tts = lk_elevenlabs.TTS(
            api_key=ELEVENLABS_API_KEY,
            voice_id=ELEVENLABS_VOICE_ID,
            model="eleven_turbo_v2_5",
        )
        logger.info("TTS: ElevenLabs voice %s", ELEVENLABS_VOICE_ID)
    else:
        tts = lk_openai.TTS(
            base_url="https://openrouter.ai/api/v1",
            api_key=OPENROUTER_API_KEY,
            voice="nova",
        )
        logger.info("TTS: OpenRouter/nova (no ELEVENLABS_API_KEY set)")

    llm = lk_openai.LLM(
        model="openai/gpt-4o-mini",
        base_url="https://openrouter.ai/api/v1",
        api_key=OPENROUTER_API_KEY,
    )

    agent = Agent(instructions=SYSTEM_PROMPT, tools=TOOLS)

    session = AgentSession(
        vad=ctx.proc.userdata["vad"],
        stt=stt,
        llm=llm,
        tts=tts,
    )

    await session.start(agent=agent, room=ctx.room)
    await session.generate_reply(
        instructions="Greet the operator briefly. Two sentences max."
    )
    await session.wait_for_disconnect()
    logger.info("session ended for room: %s", ctx.room.name)


if __name__ == "__main__":
    cli.run_app(
        WorkerOptions(
            entrypoint_fnc=entrypoint,
            prewarm_fnc=prewarm,
        )
    )
