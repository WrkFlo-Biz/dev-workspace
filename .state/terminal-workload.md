# Shared Terminal Workload

Last updated: 2026-04-25 10:55 UTC
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
- Do not answer worker edit/approval prompts from the orchestrator session;
  approvals must happen in the worker terminal on the Mac side.
- Keep verification commands visible in the pane before you mark a task done.
- If this file and old pane text disagree, this file wins.
- Ignore `/tmp/worker-queues/*` and queued prompt history unless this file
  explicitly tells you to read one; this file is the only authoritative queue.
- If another worker lands a commit in your repo first and your push is rejected,
  run `git pull --rebase origin main`, restage only your owned files, rerun
  your listed verification, then push.

## Current Assignments

### orchestrator
- Status: active
- Scope: cross-repo coordination only
- Current tasks:
  - keep this file updated as the canonical live backlog
  - keep worker assignments aligned with the actual remaining backlog
  - keep commit scopes isolated from generated files, telemetry/logs, and
    unrelated `.state/` scratch files
  - reassign idle sessions by updating this file first, then dispatching with
    `~/bin/tmux-send`
  - after any terminal relaunch or stale prompt, make sure the dispatched
    message actually lands in the chat by relying on `~/bin/tmux-send` and
    checking the pane moved off the idle prompt
  - if a heartbeat says `idle` but the owned repo already shows in-lane edits
    and no completion/blocker log exists yet, refresh the same lane instead of
    reassigning it
  - do not dispatch multiple `tmux-send` calls in parallel; it uses a shared
    tmux buffer and can cross-send prompts between sessions
  - if a worker is stuck in an interactive approval/prompt state, do not answer
    it from this orchestrator pane; clear/restart the worker prompt and
    re-dispatch so approvals happen in the worker terminal on the Mac side
  - critical review flags block new assignments; clear the live review issue
    first, then refresh the queue

### gs-5-4
- Status: standby
- Repo: `/home/moses/projects/global-sentinel`
- Last completed:
  verification-only completion of the GS approval/control surface coverage sweep
  - no code changes; targeted verification already green at `2026-04-25T10:50:14Z`
- Current task:
  - read this file before acting, then stay in `/home/moses/projects/global-sentinel`
  - standby; the GS approval/control surface coverage sweep verified green with
    no owned diff, and no newer `gs-5-4` follow-on GS lane is canonized yet
  - ignore stale prompts, `/tmp/worker-queues/*`, and any wrkflo-orchestrator
    work unless this file changes first
  - do not self-assign from stale pane history
  - wait for workload refresh before taking another GS lane
  - leave a timestamped result in `/tmp/agent-coordination.md`

### dws-codex
- Status: standby
- Repo: `/home/moses/projects/global-sentinel`
- Role: GS docs/state standby after OpenClaw demotion/state verification
- Last completed:
  verification-only completion of the GS OpenClaw demotion/state coverage sweep
  - no code changes; targeted verification already green at `2026-04-25T10:51:01Z`
- Current task:
  - read this file before acting, then stay in `/home/moses/projects/global-sentinel`
  - standby; the GS OpenClaw demotion/state coverage sweep verified green with
    no owned diff, and no newer `dws-codex` follow-on GS lane is canonized yet
  - ignore stale prompts, `/tmp/worker-queues/*`, and any wrkflo-orchestrator
    work unless this file changes first
  - do not self-assign from stale pane history
  - wait for workload refresh before taking another GS docs/state lane
  - leave a timestamped result in `/tmp/agent-coordination.md`

### dws-5-4
- Status: standby
- Repo: `/home/moses/dev-workspace`
- Last completed:
  committed/pushed the DWS safe-mode live decision correction lane
  - `cd546c5` `docs: refresh dws safe mode live decision`
- Current task:
  - read this file before acting, then stay in `/home/moses/dev-workspace`
  - standby; the safe-mode live-decision lane landed as `cd546c5`
  - ignore stale `wrkflo-orchestrator` prompts, `/tmp/worker-queues/*`, and
    any off-lane completion text; no `dws-5-4` follow-on lane is canonized yet
  - do not self-assign from stale pane history
  - wait for workload refresh before taking another DWS lane
  - when finished or blocked, leave a timestamped result in
    `/tmp/agent-coordination.md`

### gs-worker
- Status: standby
- Repo: `/home/moses/projects/global-sentinel`
- Last completed:
  verification-only completion of the GS execution-routing coverage sweep
  - no code changes; targeted verification already green at `2026-04-25T10:52:10Z`
- Current task:
  - read this file before acting, then stay in `/home/moses/projects/global-sentinel`
  - standby; the GS execution-routing coverage sweep verified green with no
    owned diff, and no newer `gs-worker` follow-on GS lane is canonized yet
  - ignore stale prompts, `/tmp/worker-queues/*`, and any wrkflo-orchestrator
    work unless this file changes first
  - do not self-assign from stale pane history
  - wait for workload refresh before taking another GS lane
  - when finished or blocked, leave a timestamped result in
    `/tmp/agent-coordination.md`

## Ready Commit Boundaries

1. `dev-workspace`
   - landed on `docs/architecture-alignment` as `cd546c5`
   - DWS safe-mode live decision verification
   - include:
     `docs/dws-safe-mode-live-decision.md`
   - allowed no-op completion:
     if the doc already matches the live installed-disabled state, do not
     create a commit; log the verification result only
   - use commit message:
     `docs: refresh dws safe mode live decision`
   - verify with:
     `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check`
     `systemctl --user is-enabled dws-sessions-init.service dws-safe-mode.service`
     `systemctl --user status dws-sessions-init.service dws-safe-mode.service --no-pager`
     `cmp -s ~/projects/dev-workspace/config/systemd-user/dws-safe-mode.service ~/.config/systemd/user/dws-safe-mode.service`
     `git diff --check -- docs/dws-safe-mode-live-decision.md`

## Quick References

- Workload: `sed -n '1,320p' /home/moses/dev-workspace/.state/terminal-workload.md`
- Progress log: `tail -n 40 /tmp/agent-coordination.md`
- Review queue: `tail -n 40 /tmp/review-requests.md`
- Dev-workspace status: `git -C /home/moses/dev-workspace status --short`
- GS status: `git -C /home/moses/projects/global-sentinel status --short`
- Orchestrator status: `git -C /home/moses/projects/wrkflo-orchestrator status --short`

## Orchestrator Dispatch Guide

All 4 workers are in tmux. Use `~/bin/tmux-send` to dispatch, never raw
`tmux send-keys`. `tmux-send` pastes the full message, presses Enter, retries if
the pane still looks idle, and verifies the worker left the prompt.

```bash
# Send task to any worker:
~/bin/tmux-send gs-5-4 "YOUR TASK"
~/bin/tmux-send gs-worker "YOUR TASK"
~/bin/tmux-send dws-5-4 "YOUR TASK"
~/bin/tmux-send dws-codex "YOUR TASK"

# Check worker output:
tmux capture-pane -t gs-5-4 -p -S -20
tmux capture-pane -t gs-worker -p -S -20
tmux capture-pane -t dws-5-4 -p -S -20
tmux capture-pane -t dws-codex -p -S -20
```

If a terminal was just relaunched or still shows an idle prompt after dispatch,
run `~/bin/tmux-send` again rather than assuming the message entered the chat.

Worker inventory:
| Session     | Repo             | Profile        | Role                    |
|-------------|------------------|----------------|-------------------------|
| gs-5-4      | global-sentinel | foundry-5_4 | standby after approval/control surface verification |
| gs-worker   | global-sentinel | full-auto | standby after execution-routing verification |
| dws-5-4     | dev-workspace | foundry-5_4 | standby after safe-mode live decision correction |
| dws-codex   | global-sentinel | foundry-codex | standby after OpenClaw demotion/state verification |
