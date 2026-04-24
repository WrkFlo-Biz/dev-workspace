#!/usr/bin/env python3
"""Write /tmp/monitor-status.json after each monitor cycle.
The orchestrator reads this to know what is done and what needs tasks."""
import json, sys, subprocess
from datetime import datetime

TASK_QUEUE = "/home/moses/projects/dev-workspace/.state/task-queue.json"
STATUS_FILE = "/home/moses/projects/dev-workspace/.state/monitor-status.json"
MONITOR_LOG = "/var/log/dws/monitor.log"

with open(TASK_QUEUE) as f:
    data = json.load(f)

completed = [t for t in data["tasks"] if t["status"] == "completed"]
in_progress = [t for t in data["tasks"] if t["status"] == "in_progress"]
pending = [t for t in data["tasks"] if t["status"] == "pending"]

# Get current worker states from tmux
workers = {}
for s in ["dws-a","dws-b","worker-c","worker-d","worker-e","worker-f","worker-g","worker-h"]:
    try:
        out = subprocess.run(["tmux","capture-pane","-t",s,"-p"],
                           capture_output=True, text=True, timeout=5)
        tail = out.stdout.strip().split("\n")[-8:]
        text = "\n".join(tail)
        if "Working" in text:
            status = "working"
        elif "compact task" in text or "high demand" in text:
            status = "compacted"
        elif "Connection" in text and "closed" in text:
            status = "disconnected"
        else:
            status = "idle"
    except:
        status = "unknown"

    current_task = None
    for t in in_progress:
        if t.get("assigned") == s:
            current_task = t["id"]
            break
    workers[s] = {"status": status, "current_task": current_task}

status = {
    "timestamp": datetime.now().isoformat(),
    "summary": {
        "completed": len(completed),
        "in_progress": len(in_progress),
        "pending": len(pending),
        "total": len(data["tasks"])
    },
    "workers": workers,
    "completed_tasks": [{"id":t["id"],"phase":t["phase"],"desc":t["description"][:60]} for t in completed],
    "pending_tasks": [{"id":t["id"],"phase":t["phase"],"repo":t["repo"],"desc":t["description"][:60]} for t in pending],
    "phases_done": {},
}

# Phase progress
for phase in range(1,7):
    phase_tasks = [t for t in data["tasks"] if t["phase"] == phase]
    phase_completed = [t for t in phase_tasks if t["status"] == "completed"]
    if phase_tasks:
        status["phases_done"][f"phase_{phase}"] = f"{len(phase_completed)}/{len(phase_tasks)}"

with open(STATUS_FILE, "w") as f:
    json.dump(status, f, indent=2)
print(f"status written: {len(completed)} done, {len(in_progress)} active, {len(pending)} pending")
