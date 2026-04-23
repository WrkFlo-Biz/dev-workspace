# dev-workspace

Azure-hosted remote dev workspace with Codex CLI wired to Azure AI Foundry,
reachable from any device (Mac, phone via Termius) 24/7 over a Tailscale mesh.

## What this is

A single repo that captures three things which used to live only in memory / in
ad-hoc shell config:

1. **The always-on Azure VM** (`dev-workspace-vm`, westus2) where Codex + Claude Code
   run against Azure Foundry deployments instead of the public OpenAI API.
2. **The Tailscale mesh** joining that VM, this Mac, and your phone so every node has
   a stable private IP regardless of Wi‑Fi or NAT.
3. **The Mac bridge** (SSH + Remote Management + File Sharing) so the VM — or Termius
   on your phone — can reach files on the Mac and run things on it.

```
 ┌──────────────┐   Tailscale mesh   ┌───────────────────────────┐
 │  iPhone /    │◄──────────────────►│  dev-workspace-vm         │
 │  Termius     │                    │  Azure westus2            │
 └──────┬───────┘                    │  codex --profile foundry  │
        │                            │  claude code              │
        ▼                            │  az / gh logged in        │
 ┌──────────────┐                    └──────────┬────────────────┘
 │  Mac         │◄──────── Tailscale ───────────┘
 │  (this box)  │   SSH / ARD / SMB
 └──────────────┘
```

## Layout

- `infra/` — Bicep describing the VM + networking (documents the current resource state;
  not deployed from here).
- `scripts/` — Idempotent setup scripts for the VM (Tailscale, codex profiles, key delivery).
- `mac-setup/` — Scripts + instructions for the Mac side (sharing services, Tailscale app, Termius key).
- `codex-profiles/` — Drop-in `~/.codex/config.toml` fragments for Foundry profiles
  (general coding, codex, voice/realtime, multimodal, Claude fallback).
- `docs/` — Longer-form docs: Termius setup, Tailscale, Foundry, troubleshooting.

## Quick start

New device (e.g. reimaged laptop, new phone):

1. **Install Tailscale** on the device, log in to the same tailnet (`wrkflo.biz` Google).
2. **Termius** → add host:
   - VM: `moses@dev-workspace-vm` (Tailscale MagicDNS name) or `moses@20.230.203.79`
   - Mac: `mosestut@mosess-macbook-air-3` once Mac-side setup is done
   - Auth: `~/.ssh/termius_20260415` (ED25519, no passphrase)

Connecting to the VM drops you into the **dev-workspace launcher** — a picker
menu for Global Sentinel, Voice Agents, OpenClaw, Quantum, and "plain shell".
Each option cd's into the right project and launches codex (or claude) with the
right Foundry profile. The Azure Foundry key is auto-loaded from
`~/.config/wrkflo/foundry.env` before the picker runs.

To bypass the launcher once (e.g. for a pure shell): `SKIP_LAUNCHER=1 ssh …`
or type `q` at the picker prompt.

See `docs/termius.md` for the full Termius flow.

## Related infrastructure (not in this repo)

- `Wrk-Flo/global-sentinel` — the primary project that runs on this VM.
- `Wrk-Flo/openclaw-prod` — separate Container Apps deployment (different VM).
- Azure AI Foundry resource: `moses-8586-resource` in `rg-moses-8586` (eastus2) —
  hosts all the codex deployments this workspace routes to.
