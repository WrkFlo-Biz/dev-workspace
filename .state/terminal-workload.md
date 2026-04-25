# Shared Terminal Workload

Last updated: 2026-04-25 UTC
Canonical path: `/home/moses/dev-workspace/.state/terminal-workload.md`

This file is the live source of truth for terminal assignments. If a session
goes idle, loses context, or finishes a task, reopen this file first.

## Default Loop

1. Read this file at session start and after every task completion.
2. Stay inside your assigned repo and owned files.
3. Do not self-assign from stale pane history. Re-check this file first.
4. When you finish or block, append one timestamped line to
   `/tmp/agent-coordination.md` with session name, result, verification run,
   and any blocker.
5. If your status is `standby`, wait for reassignment here or from the
   orchestrator session.

## Shared Rules

- Do not revert someone else's edits.
- One repo per worker at a time unless this file explicitly says otherwise.
- Do not commit or push unless the assignment explicitly says so.
- Keep verification commands visible in the pane before you mark a task done.
- If this file and old pane text disagree, this file wins.

## Current Assignments

### orchestrator
- Status: active
- Scope: cross-repo coordination only
- Current tasks:
  - keep this file updated as the canonical live backlog
  - keep worker assignments aligned with the remaining clean commit/push lanes
  - keep commit scopes isolated from generated files, telemetry/logs, and
    unrelated untracked docs/state
  - reassign idle sessions by updating this file first, then dispatching with
    `~/bin/tmux-send`

### gs-5-4
- Status: active
- Repo: `/home/moses/projects/global-sentinel`
- Context refresh: complete
  - loaded `CLAUDE.md`, `AGENTS.md`, `SOUL.md`, `USER.md`, `MEMORY.md`,
    `memory/2026-04-24.md`, and `memory/2026-04-25.md`
  - active GS guidance: `pytest -q tests/ -p no:cacheprovider`
  - active GS work themes: OpenClaw demotion, Foundry/orchestrator routing,
    Tier-2 approval mediation
- Last completed:
  `env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. python3 -m pytest -q tests/ -p no:cacheprovider`
  -> `768 passed, 1 skipped, 3 warnings`
- Current task:
  - read this file before acting, then stay in `/home/moses/projects/global-sentinel`
  - current GS `HEAD` already contains the docs-only commit
    `7fc9bfd docs: add GS migration status for orchestrator migration lane`
  - push that existing local `main` commit to `origin/main`
  - do not stage, commit, or modify any other GS files
  - leave a timestamped result in `/tmp/agent-coordination.md`

### dws-codex
- Status: active
- Repo: `/home/moses/dev-workspace`
- Last completed: `docs/runbook.md` live-state/runbook correction lane
- Reserved file until committed: `docs/runbook.md`
- Last commit:
  - `7bae487` `docs: update runbook with live service state, boot policy, verification commands`
- Current task:
  - read this file before acting, then stay in `/home/moses/dev-workspace`
  - review, commit, and push the `dws-update` follow-up set only:
    `docs/setup.md`, `scripts/dws-update.sh`, `tests/test_dws_update.sh`
  - verify with:
    `env PYTHONDONTWRITEBYTECODE=1 bash tests/test_dws_update.sh`
  - do not include `docs/runbook.md`, workload-state files, or unrelated
    untracked docs
  - leave a timestamped result in `/tmp/agent-coordination.md`

### dws-5-4
- Status: active
- Repo: `/home/moses/dev-workspace`
- Last completed:
  `env PYTHONDONTWRITEBYTECODE=1 bash tests/test_dws_update.sh`
  -> `PASS: test_dws_update.sh`
- Current task:
  - read this file before acting, then stay in `/home/moses/dev-workspace`
  - review, commit, and push the workload-infrastructure lane only:
    `scripts/dws-orchestrator-boot.sh`,
    `.state/terminal-workload.md`
  - verify with:
    `bash -n scripts/dws-orchestrator-boot.sh`
    and
    `git diff --check -- scripts/dws-orchestrator-boot.sh .state/terminal-workload.md`
  - do not include `docs/setup.md`, `scripts/dws-update.sh`,
    `tests/test_dws_update.sh`, or any unrelated `.state/` files
  - leave a timestamped result in `/tmp/agent-coordination.md`

## Ready Commit Boundaries

1. `global-sentinel`
   - push existing local commit `7fc9bfd`
2. `global-sentinel`
   - `src/monitoring/telegram_topic_notifier.py`
   - `scripts/agent_factory.py`
   - `tests/test_telegram_topic_notifier.py`
   - `tests/dashboard/test_portfolio_api.py`
   - verify with:
     `env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. python3 -m pytest -q tests/ -p no:cacheprovider`
2. `dev-workspace`
   - `docs/setup.md`
   - `scripts/dws-update.sh`
   - `tests/test_dws_update.sh`
   - verify with:
     `env PYTHONDONTWRITEBYTECODE=1 bash tests/test_dws_update.sh`
3. `dev-workspace`
   - `scripts/dws-orchestrator-boot.sh`
   - `.state/terminal-workload.md`
   - verify with:
     `bash -n scripts/dws-orchestrator-boot.sh`
     and
     `git diff --check -- scripts/dws-orchestrator-boot.sh .state/terminal-workload.md`
   - `docs/setup.md`

## Quick References

- Workload: `sed -n '1,260p' /home/moses/dev-workspace/.state/terminal-workload.md`
- Progress log: `tail -n 40 /tmp/agent-coordination.md`
- Dev-workspace status: `git -C /home/moses/dev-workspace status --short`
- GS status: `git -C /home/moses/projects/global-sentinel status --short`

### gs-worker
- Status: active
- Repo: `/home/moses/projects/global-sentinel`
- tmux session: `gs-worker`
- Dispatch: `tmux send-keys -t gs-worker "YOUR TASK HERE" Enter`
- Last completed: (new session)
- Current task:
  - read this file before acting, then stay in `/home/moses/projects/global-sentinel`
  - review, commit, and push the GS code/test fix set only:
    `scripts/agent_factory.py`,
    `src/monitoring/telegram_topic_notifier.py`,
    `tests/test_telegram_topic_notifier.py`,
    `tests/dashboard/test_portfolio_api.py`
  - verify with:
    `env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. python3 -m pytest -q tests/ -p no:cacheprovider`
  - do not include `docs/migration-status.md`, `logs/`, `telemetry/`, `.codex/`,
    or `data/`
  - leave a timestamped result in `/tmp/agent-coordination.md`

## Orchestrator Dispatch Guide

All 4 workers are in tmux. Use `tmux send-keys` to dispatch:

```bash
# Send task to any worker:
tmux send-keys -t gs-5-4 "YOUR TASK" Enter
tmux send-keys -t gs-worker "YOUR TASK" Enter
tmux send-keys -t dws-5-4 "YOUR TASK" Enter
tmux send-keys -t dws-codex "YOUR TASK" Enter

# Check worker output:
tmux capture-pane -t gs-5-4 -p -S -20
tmux capture-pane -t gs-worker -p -S -20
tmux capture-pane -t dws-5-4 -p -S -20
tmux capture-pane -t dws-codex -p -S -20
```

Worker inventory:
| Session     | Repo             | Profile        | Role                    |
|-------------|------------------|----------------|-------------------------|
| gs-5-4      | global-sentinel  | foundry-5_4    | GS migration/docs       |
| gs-worker   | global-sentinel  | full-auto      | GS test sweep/fixes     |
| dws-5-4     | dev-workspace    | foundry-5_4    | DWS drift/doc fixes     |
| dws-codex   | dev-workspace    | foundry-codex  | DWS runbook/docs        |
