# dev-workspace
Remote dev environment on an Azure VM, reachable from Mac and phone over
Tailscale. This repo also carries the canonical platform and architecture docs
for Wrk-Flo.

## Architecture Frames

Wrk-Flo keeps three architecture views separate:

- Canonical product architecture: the provider-agnostic seven-layer model in
  [docs/wrkflo-7layer-vision.md](docs/wrkflo-7layer-vision.md)
- Current implementation stack: the live operator environment in
  [docs/architecture.md](docs/architecture.md) and the Azure-first substrate in
  [docs/implementation-substrate.md](docs/implementation-substrate.md)
- Target production topology: platform governance and memory/storage boundaries
  in [docs/governance.md](docs/governance.md) and
  [docs/memory-architecture.md](docs/memory-architecture.md)

GitHub Enterprise is the governance and deployment spine. GitHub Secrets is
CI/CD-scoped only. Runtime secrets belong in Azure Key Vault with managed
identities rather than in repo or pipeline secret stores.

## Quick Start
Mac:
1. Join the same Tailscale tailnet as the VM.
2. Double-click `mac-setup/dev-workspace.command`.
3. SSH lands on `dev-workspace-vm`; the launcher opens, then you pick project + model and work inside `tmux`.

Phone:
1. Install Tailscale and Termius, then join the same tailnet.
2. Import your SSH key into Termius.
3. Add host `moses@dev-workspace-vm` in Termius. Fallback IP: `20.230.203.79`.
4. Connect, pick a project + model in the launcher, and use `r` later to reconnect to an existing `tmux` session.

## Architecture
`Mac / iPhone -> Tailscale -> dev-workspace-vm -> tmux -> Codex / Claude`

- This path is the current implementation stack for the operator workspace, not
  the canonical product architecture.
- Interactive SSH logins land in `scripts/dws-launcher.sh`.
- The launcher starts or reattaches a `tmux` session, then runs `codex --profile ...` or `claude`.
- VM-to-Mac bridges are `http://100.78.207.22:9222` (Chrome CDP) and `http://100.78.207.22:9223` (GUI/Hammerspoon).

## Supported Models
Azure Foundry launcher targets plus native Claude Code:

| Key | Model | Profile/tool |
| --- | --- | --- |
| `1` | `gpt-5.4` | `foundry-5_4` |
| `2` | `gpt-5.2` | `foundry-5_2` |
| `3` | `gpt-5.2-codex` | `foundry-codex` |
| `4` | `gpt-5.1-codex-mini` | `foundry-mini` |
| `5` | `gpt-5-mini` | `foundry-5-mini` |
| `6` | `gpt-4o` | `foundry-4o` |
| `7` | `claude-opus-4-6` | `foundry-opus` |
| `8` | `claude-sonnet-4-6` | `foundry-sonnet` |
| `9` | `claude-haiku-4-5` | `foundry-haiku` |
| `c` | Claude Code CLI | `claude` |

## Projects
| Code | Repo | Purpose |
| --- | --- | --- |
| `gs` | `global-sentinel` | Primary geopolitical / macro runtime |
| `voice` | `wrkflo-voice-agents-ops` | Voice-agent audit, safety, and ops |
| `oclaw` | `openclaw-prod` | OpenClaw gateway, runtime, deploy work |
| `gsaq` | `global-sentinel-azure-quantum` | Quantum experiments and notes |
| `orch` | `wrkflo-orchestrator` | Multi-agent control plane |
| `dws` | `dev-workspace` | This repo: VM, launcher, bridge, and ops tooling |

## Scripts

This table is intentionally curated rather than exhaustive. For the full tracked
surface, run `rg --files scripts bin | sort`.

| Script | Purpose |
| --- | --- |
| `apply-codex-profiles.sh` | Merge Foundry profiles into `~/.codex/config.toml` |
| `control-mac-chrome.js` | Example Puppeteer client for the Mac Chrome CDP bridge |
| `control-mac-chrome.sh` | Wrapper that sets `NODE_PATH` and runs the Chrome CDP script |
| `control-mac-gui.py` | CLI for the Mac Hammerspoon GUI bridge |
| `dws-backup.sh` | Snapshot launcher/runtime state, verify restoreability, and prune expired backup artifacts |
| `dws-cleanup.sh` | Trim stale worktrees, old tmux sessions, old logs, and temp artifacts |
| `dws-cron-setup.sh` | Install or verify the managed `dws` cron block |
| `dws-doctor.sh` | Pass/warn/fail health checks for runtime, cron, backups, cleanup, and artifacts |
| `dws-env.sh` | Shared project/model mappings and Mac bridge env vars |
| `dws-health.sh` | Health dashboard for mesh, sessions, tooling, auth, and HTTP endpoints |
| `dws-launcher.sh` | SSH login picker for project, model, session attach, and status |
| `dws-log.sh` | Unified log viewer for health, alerts, sync, and Mac bridge logs |
| `dws-phone-server.py` | VM-side HTTP queue for iPhone Shortcut actions |
| `dws-quick.sh` | Fast non-menu launcher for `<project-short> <model-short>` |
| `dws-sessions.sh` | List session history, inspect recovery state, reconnect, recover, relaunch, or clean up `tmux` sessions |
| `dws-update.sh` | Pull repo updates and deploy tracked config/script changes |
| `sync-mac-to-vm.sh` | `rsync` a local Mac folder up to the VM |
| `sync-vm-to-mac.sh` | `rsync` a VM folder back down to the Mac |
| `vm-bootstrap.sh` | Lightweight idempotent VM bootstrap |
| `vm-setup.sh` | Full Ubuntu VM setup for packages, repos, profiles, and services |

## Tests

Run the repo shell suite with:

```bash
bash tests/run_all.sh
```

## Backup Verification

Validate the latest snapshot without touching live runtime files:

```bash
~/projects/dev-workspace/bin/dws-backup.sh verify-restore
```

That flow restores the snapshot into a temp directory, checks `state.db`,
`task-queue.json`, `planner-status.md`, and both monitor logs, then only
reports success if those artifacts restore cleanly.

Use `~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest --prune`
when you also want to prune expired backup and verify scratch directories.

## Doctor Checks

Use the doctor when the VM feels off or before launching more workers:

```bash
~/projects/dev-workspace/bin/dws-doctor.sh
```

It validates:

- root disk usage and memory pressure
- Tailscale connectivity and active `tmux` sessions
- the exact managed cron block installed by `dws-cron-setup.sh`
- the latest backup under `~/backups/dev-workspace` (warn after 24h, fail after 48h by default)
- the latest successful cleanup via `/tmp/dws-cleanup.last-success`, with cron-log fallback for older installs
- planner or monitor artifact freshness, and points you at `dws-status.sh` plus the relevant log tail when the runtime looks stale

## tmux Cheatsheet
Prefix is `Ctrl-a`.

| Keys | Action |
| --- | --- |
| `Ctrl-a d` | Detach and leave the session running |
| `Ctrl-a c` | New window |
| `Ctrl-a n` / `p` | Next / previous window |
| `Ctrl-a |` | Split pane vertically |
| `Ctrl-a -` | Split pane horizontally |
| `Ctrl-a h/j/k/l` | Move between panes |
| `Ctrl-a [` | Scroll / copy mode |
| `Ctrl-a H` | Open the health popup |
| `Ctrl-a m` | Toggle mouse mode |
| `Ctrl-a r` | Reload `~/.tmux.conf` |

## Troubleshooting
- No launcher: interactive SSH only; unset `SKIP_LAUNCHER=1` or run `~/bin/dws-launcher.sh`.
- Foundry key missing: check `~/.config/wrkflo/foundry.env`, then run `~/projects/dev-workspace/bin/dws-status.sh` or `~/projects/dev-workspace/scripts/dws-health.sh`.
- Cannot reach the VM: verify Tailscale on both devices, try `dev-workspace-vm`, then fall back to `20.230.203.79`.
- Lost your session: reconnect and press `r`, or run `~/projects/dev-workspace/bin/dws-sessions.sh list`, `show`, and `reconnect`.
- Mac automation is down: make sure the Mac is awake and on Tailscale; test ports `9222` and `9223`.
- Repo or local tooling drift: run `~/projects/dev-workspace/scripts/dws-update.sh` on the VM.
