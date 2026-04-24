# Dev Workspace Orchestrator Context

Updated: 2026-04-24 05:23 UTC

The runtime model is orchestrator-first. Repo-owned state in `.state/` should
stay small, current, and limited to active coordination data.

## Projects

| Repo | Path | Purpose |
|------|------|---------|
| dev-workspace | ~/projects/dev-workspace | VM infra, scripts, monitoring, self-healing |
| global-sentinel | ~/projects/global-sentinel | Core trading/market intelligence platform |
| global-sentinel-azure-quantum | ~/projects/global-sentinel-azure-quantum | Quantum computing integration |
| wrkflo-orchestrator | ~/projects/wrkflo-orchestrator | Multi-agent orchestration framework |
| wrkflo-voice-agents-ops | ~/projects/wrkflo-voice-agents-ops | Voice agent operations |
| openclaw-prod | ~/projects/openclaw-prod | Legal/compliance platform |

## Runtime Model

- `wrkflo-orchestrator` is the control plane for task dispatch and subprocess
  execution.
- Repo-owned user units are `dws-sessions-init.service` and
  `dws-safe-mode.service`. The legacy bash monitor unit has been removed from
  repo-owned config and should not be reintroduced here.
- `dws-safe-mode.sh on|off|status` coordinates with the initializer while
  leaving SSH, Tailscale, health checks, and log rotation available.
- Persistent tmux worker pools are deprecated. Worker names in queue metadata
  are routing hints, not a guarantee of long-lived tmux sessions.
- `worker-labels.json` remains the label source of truth for routing.

## Task State

- Queue file: `~/projects/dev-workspace/.state/task-queue.json`
- Expected format: `{"tasks": [...]}`.
- Keep only `pending` or `in_progress` items in the live queue.
- An empty queue is the normal steady state between dispatch cycles.
- Historical queue snapshots and monitor dumps do not belong in repo-owned
  `.state/`.

## Network Posture

- SSH is intended to be Tailscale-only. `scripts/dws-firewall.sh --verify`
  fails if `tcp/22` is public.
- Expected allowlist: `tcp/22` and dev ports only from `100.64.0.0/10`;
  `udp/41641` remains public for Tailscale peer traffic.

## Worker Labels

Location: `~/projects/dev-workspace/.state/worker-labels.json`

Format:
`{"version": 1, "workers": {"WORKER_NAME": ["label", "..."]}}`

Supported labels:
- `infra`: VM, tmux, systemd, shell scripts, runtime operations, deployment plumbing
- `docs`: runbooks, README/docs updates, architecture notes, operator instructions
- `test`: test authoring, test execution, regression reproduction, CI-style verification
- `sync`: merge/rebase/cherry-pick work, conflict cleanup, branch hygiene, staging coordination
- `foundry-heavy`: tasks that benefit from the managed `foundry-5_4` profile or heavier reasoning

Labels are optional defaults. They improve first-pass routing but do not
override repo access, file ownership, or the current runtime topology.

## Your Role

1. Read code, make edits, and run commands directly when needed.
2. Break operator requests into non-overlapping tasks and route them safely.
3. Keep live state small and accurate so the orchestrator can recover cleanly.
4. Prefer orchestrator-managed execution over reviving deprecated monitor flows.

## Commands

Check queue:
`python3 -c "import json; d=json.load(open('$HOME/projects/dev-workspace/.state/task-queue.json')); print(f'pending={sum(1 for t in d[\"tasks\"] if t[\"status\"]==\"pending\")} in_progress={sum(1 for t in d[\"tasks\"] if t[\"status\"]==\"in_progress\")} total={len(d[\"tasks\"])}')"`

Check services:
`systemctl --user status wrkflo-orchestrator-api.service dws-sessions-init.service`

Pause dispatch:
`~/projects/dev-workspace/bin/dws-pause-dispatch.sh status`

Export incident:
`~/projects/dev-workspace/bin/dws-incident-export.sh`

Safe mode:
`~/projects/dev-workspace/bin/dws-safe-mode.sh status`

Verify Tailscale-only SSH:
`~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --verify`
