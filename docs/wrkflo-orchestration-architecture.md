---
name: Wrk-Flo Multi-Agent Orchestration Architecture
description: Current dev-workspace orchestration stack, two-tier orchestrator pattern, and how the live system maps to the canonical Wrk-Flo 7-layer architecture
type: project
originSessionId: 3dcbe974-5fb5-4591-8353-cecc0be17ae8
---
## Purpose

This document describes the current live orchestration stack and how it maps to
the canonical Wrk-Flo product model. It is not a second canonical seven-layer
architecture.

## Architecture Framing

| View | Role | Primary docs |
| --- | --- | --- |
| Canonical product architecture | Stable provider-agnostic product model | [wrkflo-7layer-vision.md](./wrkflo-7layer-vision.md) |
| Current implementation stack | Live operator environment and orchestration mechanics | this document, [architecture.md](./architecture.md), [implementation-substrate.md](./implementation-substrate.md) |
| Target production topology | Deployment, governance, and storage boundaries | [current-implementation-vs-canonical.md](./current-implementation-vs-canonical.md), [governance.md](./governance.md), [memory-architecture.md](./memory-architecture.md) |

## Current Live Architecture (as of 2026-04-25)

### Two-Tier Orchestrator Pattern

Proven pattern running on the current Azure VM operator stack:

**Tier 1 — Supervisor** (`orchestrator-supervisor.sh`, bash, immortal)
- 15-second heartbeat cycle
- Dashboard: worker status, API health, systemd state, git dirty count, review flags
- Detects idle/done/dead workers → nudges orch-agent to reassign
- Continuous code review: runs `code-review.sh` every heartbeat, writes `/tmp/review-snapshot.md`
- On worker done transition: sends review context to orch-agent (diffs, flags, live state) before next assignment
- On critical review flags (hardcoded creds, API regression, unsafe patterns): alerts orch-agent immediately
- User interactive CLI: send, peek, restart, review, commit, push, nudge
- Free-text input forwarded to orch-agent
- Never assigns tasks, never edits code — just rings the bell and flags problems
- Runs in tmux `orchestrator` session

**Tier 2 — Sub-Orchestrator** (`orch-agent`, Codex AI agent)
- Reads workload file, decides task assignments
- Updates `.state/terminal-workload.md` (single source of truth)
- Dispatches workers via `~/bin/tmux-send`
- Monitors completion via `tmux capture-pane`
- Reviews worker diffs when supervisor sends review context (checks code quality, test results, live state)
- Never does actual code/test work — coordinate and review only
- Runs in tmux `orch-agent` session
- Restartable by watchdog if it compacts/crashes

**Watchdog** (`codex-watchdog.sh`, 30s cycle)
- Checks all sessions alive via `kill -0 $pane_pid`
- Checks Codex workers have child processes via `pgrep -a -P $pid | grep codex|node`
- Detects error patterns: compact errors, out of context, session expired, panic
- Auto-restarts via `codex-restart.sh` → SSHs to Mac → opens Terminal window
- Supervisor health check uses `kill -0` not `pgrep -P` (bash `read -t` has no children)

### Worker Fleet

Worker session names are durable operator handles, not stable architecture
identities. The repo assignment behind a pane can change with the shared
workload file. Typical live sessions include:

- `orchestrator`
- `gs-5-4`
- `gs-worker`
- `dws-5-4`
- `dws-codex`

That is why repo ownership and task scope live in
`/home/moses/dev-workspace/.state/terminal-workload.md` instead of being
hard-coded into the architecture model.

### Coordination Files

- **Workload**: `/home/moses/dev-workspace/.state/terminal-workload.md` — canonical task assignments, all agents read this
- **Coordination log**: `/tmp/agent-coordination.md` — append-only timestamped worker results
- **Review snapshot**: `/tmp/review-snapshot.md` — refreshed every 15s by supervisor, contains git diffs, live state, drift checks, security flags

### Code Review Layer (`code-review.sh`)

Runs every 15s as part of supervisor heartbeat. Checks:
- **Uncommitted changes**: git diff per repo (staged + unstaged), diff preview
- **Unpushed commits**: local commits ahead of origin/main
- **API regression**: verifies all endpoints still return 200
- **Service drift**: systemd active/enabled state, unit file repo vs live comparison
- **Worker fleet**: error detection in pane output (traceback, panic, fatal)
- **Security flags**: hardcoded credentials, debug markers (pdb/breakpoint), unsafe patterns (eval/exec/shell=True)
- **Test state**: latest test results from coordination log

Flow: supervisor runs review → writes snapshot → if critical flags, alerts orch-agent immediately → if worker just finished, sends diff context to orch-agent for review before next assignment
- **Supervisor log**: `/tmp/orchestrator-supervisor.log`

### Key Scripts (all in `~/bin/`)

- `orchestrator-supervisor.sh` — heartbeat + dashboard + code review + CLI
- `code-review.sh` — continuous code review: diffs, live state, drift, security flags → `/tmp/review-snapshot.md`
- `codex-watchdog.sh` — process health monitor + auto-restart
- `codex-restart.sh` — session registry, kill/recreate tmux, Mac terminal popup
- `tmux-send` — reliable message delivery to tmux sessions
- `open-codex-terminal.sh` — Mac-side script to open Terminal window with SSH+tmux attach

### Review and Recovery Loops

```
Every 15s: Supervisor checks workers → detects idle → nudges orch-agent
           Orch-agent reads workload → assigns task → dispatches via tmux-send
           Worker executes → logs to coordination file → goes idle
           Next 15s tick picks it up again
```

### Full Crash Recovery Loop

```
Every 30s: Watchdog checks sessions → detects crash/compact/error
           codex-restart.sh kills session → recreates tmux → sends context
           SSHs to Mac → open-codex-terminal.sh opens visible Terminal window
           Worker restarts, reads workload file for assignment
```

### Systemd Services

- `wrkflo-orchestrator-api.service` — enabled at boot, HTTP on 127.0.0.1:8100
- `dws-sessions-init.service` — boot bootstrap for on-demand tmux model
- `dws-phone-server.service` — phone callback server

### API Surface (wrkflo-orchestrator, port 8100)

- `/healthz` — service health
- `/v1/workers` — worker registry (azure, browser, cli, codex_subprocess, github, repo)
- `/v1/projects` — workspace projects
- `/v1/workspace/projects` — workspace projects (alias)
- `/v1/workspace/health` — VM health (Tailscale, disk, memory, uptime)
- `/v1/tasks/history` — run history

### Authoring And Runtime Boundary

- Langflow is the workflow-template and visual-authoring surface.
- `wrkflo-orchestrator` is the runtime control plane and execution authority.
- Langflow-authored flows may describe workflow shape or hand off compiled
  runtime input, but the builder is not the system of record for approvals,
  retries, policy, audit, or live state transitions.

### Runtime State Boundary

The live stack still coordinates work with the workload file, coordination log,
review snapshot, and append-only state in the sibling orchestrator. The durable
runtime contract remains a split between hot coordination state and durable
truth:

- hot coordination: queue state, leases, claims, timers, approval-token caches,
  and similar ephemeral runtime control data
- durable truth: approvals, immutable run history, lineage, audit evidence, and
  terminal workflow state

In the production direction, Redis or an equivalent ephemeral store owns the
hot coordination path, while durable relational storage owns the system-of-
record history.

### Live Role Vocabulary

The current stack already maps to the durable Wrk-Flo role vocabulary:

- **Chief orchestrator**: `orchestrator-supervisor.sh` plus `orch-agent`
- **Sub-orchestrators**: workload-scoped domain lanes coordinated through
  `.state/terminal-workload.md`
- **Workers / doers**: repo-focused Codex or Claude panes that execute assigned
  slices
- **Tool operators**: repo, browser, CLI, GitHub, and HTTP adapters behind
  worker actions
- **Critic / reviewer**: `code-review.sh` plus the supervisor review loop

Planner, retriever, and presenter responsibilities still exist mostly as ad hoc
behavior in the current operator stack. They remain part of the architecture
vocabulary even when they are not yet split into dedicated long-running roles.

## Mapping To The Canonical 7 Layers

The public seven-layer model lives in
[wrkflo-7layer-vision.md](./wrkflo-7layer-vision.md). The table below explains
how the live system maps to that model without redefining it.

| Canonical layer | Live implementation today | Production direction |
| --- | --- | --- |
| Interfaces | SSH launcher, Termius, `tmux`, operator CLI, phone callback path | add chat, voice, dashboard, and public API surfaces with cleaner product UX |
| Chief orchestrator | `orchestrator-supervisor.sh` plus `orch-agent` | durable orchestrator service with typed contracts and explicit workflow control |
| Sub-orchestrators | operator-assigned domain lanes coordinated through workload files | domain-scoped orchestrators with formal contracts and bounded responsibilities |
| Specialist agents | Codex/Claude worker panes, repo/browser/github/cli adapters, review automation | typed planner, worker, critic, presenter, and retriever roles |
| Tool/integration fabric | worker modules, Mac bridges, repo tooling, shell and HTTP adapters | MCP-backed connectors, SaaS integrations, and external runtime adapters |
| Memory/state/evidence | workload file, coordination log, review snapshot, append-only state in the sibling orchestrator | Redis for hot coordination, durable relational storage for truth, vector retrieval for lookup |
| Security/governance/compliance | approval tokens, review gates, environment hygiene, branch/process controls | tenant isolation, policy packs, stronger audit export, and formal promotion controls |

## Infrastructure Runtime Boundary

The orchestration stack sits on an Azure-first implementation substrate, but
that substrate is not a public architectural layer:

- GitHub Enterprise is the governance and deployment spine
- GitHub Secrets is CI/CD-scoped only
- runtime secrets belong in Azure Key Vault with managed identities
- Azure App Service is the current planned public-surface step
- Front Door or Application Gateway may be added later if WAF or public routing
  requirements justify them
- Cloudflare is not part of the current Azure-first implementation path
- OpenClaw and similar external runtimes integrate via API, not as local tmux
  workers

See [implementation-substrate.md](./implementation-substrate.md),
[governance.md](./governance.md), and
[memory-architecture.md](./memory-architecture.md) for the boundary details.

## Key Design Principle

The two-tier orchestrator pattern remains the core implementation lesson from
the current stack: keep the heartbeat and recovery loop in a durable process
manager, and keep the AI decision layer restartable. The durable layer prevents
context exhaustion from becoming a system outage.
