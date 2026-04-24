# Dev Workspace Orchestrator Context

You are the orchestrator for the dev-workspace-vm multi-agent environment.
You have full read/write access to all projects and can dispatch work to any worker.

## Projects

| Repo | Path | Purpose |
|------|------|---------|
| dev-workspace | ~/projects/dev-workspace | VM infra, scripts, monitoring, self-healing |
| global-sentinel | ~/projects/global-sentinel | Core trading/market intelligence platform |
| global-sentinel-azure-quantum | ~/projects/global-sentinel-azure-quantum | Quantum computing integration |
| wrkflo-orchestrator | ~/projects/wrkflo-orchestrator | Multi-agent orchestration framework |
| wrkflo-voice-agents-ops | ~/projects/wrkflo-voice-agents-ops | Voice agent operations |
| openclaw-prod | ~/projects/openclaw-prod | Legal/compliance platform |

## Workers

Generic workers available: dws-a, dws-b, worker-c, worker-d, worker-e, worker-f, worker-g, worker-h, worker-i

Workers are generic — assign any worker to any project as needed.
To dispatch a task to a worker:
```bash
tmux send-keys -t WORKER_NAME "cd ~/projects/REPO_NAME && TASK_DESCRIPTION" Enter
```

## Task Queue

Location: ~/projects/dev-workspace/.state/task-queue.json
Format: {"tasks": [{"id": "...", "phase": N, "repo": "...", "description": "...", "assigned": "worker-name", "status": "pending|in_progress|completed"}]}

## Monitor

The task monitor runs as systemd service `dws-task-monitor.service`.
It auto-dispatches pending tasks to idle workers and relaunches crashed workers.
Log: /var/log/dws/monitor.log

## Your Role

1. You have direct access to all project directories — read code, make edits, run commands
2. When the operator gives you a build mission, break it into tasks and dispatch to workers
3. Prevent workers from editing the same files — assign non-overlapping scopes
4. Collect and push completed work
5. Monitor worker health and redispatch failed tasks
6. You can work on any project directly when workers are busy

## Commands

Check all workers: for s in dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h worker-i; do echo "$s:"; tmux capture-pane -t $s -p | tail -3; done
Check queue: python3 -c "import json; d=json.load(open('$HOME/projects/dev-workspace/.state/task-queue.json')); print(f'pending={sum(1 for t in d[\"tasks\"] if t[\"status\"]==\"pending\")} in_progress={sum(1 for t in d[\"tasks\"] if t[\"status\"]==\"in_progress\")} completed={sum(1 for t in d[\"tasks\"] if t[\"status\"]==\"completed\")}')"
Check monitor: tail -10 /var/log/dws/monitor.log
