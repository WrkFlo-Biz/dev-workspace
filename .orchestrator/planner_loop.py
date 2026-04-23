#!/usr/bin/env python3
import json
import os
import re
import time
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path

QUEUE_PATH = Path("/tmp/task-queue.json")
MONITOR_LOG_PATH = Path("/tmp/monitor-log.txt")
PLANNER_LOG_PATH = Path("/tmp/planner-log.txt")
STATUS_PATH = Path("/tmp/planner-status.md")
STATE_PATH = Path("/tmp/planner-state.json")
INTERVAL_SECONDS = int(os.environ.get("PLANNER_INTERVAL_SECONDS", "600"))


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def planner_log(message: str) -> None:
    PLANNER_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with PLANNER_LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(f"[{utc_now()}] {message}\n")


CANONICAL_TASKS = [
    {
        "id": "p0-runtime-truth",
        "phase": 0,
        "repo": "wrkflo-orchestrator",
        "description": "Verify actual orchestrator runtime truth, document real ports/framework/endpoints/state persistence/demo worker reality, and commit docs/current-runtime-truth.md.",
        "assigned": "dws-a",
        "status": "completed",
    },
    {
        "id": "p1-health-wire",
        "phase": 1,
        "repo": "dev-workspace",
        "description": "Wire dws-launcher.sh status display to read from orchestrator health API. Add a dws-status CLI command that queries localhost:8100/v1/workspace/health. Update dws-motd.sh to show orchestrator health on login. Stage, commit, push.",
        "assigned": "worker-g",
        "status": "in_progress",
    },
    {
        "id": "p1-approval-flow",
        "phase": 1,
        "repo": "wrkflo-orchestrator",
        "description": "Confirm and test the HMAC-SHA256 approval token flow for Tier-2 operations. Write integration tests for the approval endpoint. Verify dual-key rotation works. Update docs to match. Stage, commit, push.",
        "assigned": "dws-b",
        "status": "in_progress",
    },
    {
        "id": "p1-health-cli-doc-sync",
        "phase": 1,
        "repo": "dev-workspace",
        "description": "Finish the launcher-facing health CLI and runtime-doc sync in dev-workspace: add shellable orchestrator health query support and update docs so login/status surfaces match the live orchestrator API. Avoid files actively owned by the current launcher-wire task if they are still in progress. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p2-github-worker",
        "phase": 2,
        "repo": "wrkflo-orchestrator",
        "description": "Create workers/github_worker.py — a real GitHub ops worker using gh or PyGithub for listing issues, creating PRs, and posting comments, with Tier 0/1/2 classification, dry-run mode, and audit logging. Stage, commit, push.",
        "assigned": "dws-b",
        "status": "completed",
    },
    {
        "id": "p2-repo-worker",
        "phase": 2,
        "repo": "wrkflo-orchestrator",
        "description": "Create workers/repo_worker.py — a real repo editing worker that can inspect and apply focused patches, with Tier 0/1/2 classification, dry-run mode, and audit logging. Stage, commit, push.",
        "assigned": "worker-c",
        "status": "completed",
    },
    {
        "id": "p2-browser-worker",
        "phase": 2,
        "repo": "wrkflo-orchestrator",
        "description": "Create workers/browser_worker.py — a Chrome DevTools Protocol worker that can navigate pages, take screenshots, and extract text via CDP on port 9222. Add Tier classification, dry-run mode, audit logging. Stage, commit, push.",
        "assigned": "worker-c",
        "status": "in_progress",
    },
    {
        "id": "p2-azure-worker",
        "phase": 2,
        "repo": "wrkflo-orchestrator",
        "description": "Create workers/azure_worker.py — Azure resource operations worker for listing Foundry deployments, checking quotas, and managing model endpoints. Add Tier classification, dry-run mode, audit logging. Stage, commit, push.",
        "assigned": "worker-f",
        "status": "in_progress",
    },
    {
        "id": "p3-trade-approval-failclosed",
        "phase": 3,
        "repo": "global-sentinel",
        "description": "Make trade_approval.py fail closed on every dangerous path: missing approval, parse failure, backend failure, or audit failure must all reject by default. Add focused tests. Stage, commit, push.",
        "assigned": "worker-d",
        "status": "in_progress",
    },
    {
        "id": "p3-gs-test-suite",
        "phase": 3,
        "repo": "global-sentinel",
        "description": "Create a test suite for trade_approval.py that verifies all fail-closed behavior. Test that every error path results in rejection and that audit logs are written on every rejection. Stage, commit, push.",
        "assigned": "worker-e",
        "status": "completed",
    },
    {
        "id": "p3-smart-router-bridge",
        "phase": 3,
        "repo": "global-sentinel",
        "description": "Inspect smart_inference_router.py and either collapse it into the Foundry client shim or create a deprecation bridge. Update only directly related integration/tests. Stage, commit, push.",
        "assigned": "worker-e",
        "status": "in_progress",
    },
    {
        "id": "p3-foundry-callers",
        "phase": 3,
        "repo": "global-sentinel",
        "description": "Verify all model inference callers route through foundry_client.py. Grep the entire repo for remaining smart_inference_router imports or legacy inference entrypoints and refactor any stragglers. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p3-remove-auto-git-commit",
        "phase": 3,
        "repo": "global-sentinel",
        "description": "Remove auto_git_commit.sh from unattended or runtime paths and update only the directly related ops/docs references to reflect the removal. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p4-project-cards",
        "phase": 4,
        "repo": "wrkflo-orchestrator",
        "description": "Add project cards to WorkspaceBroker registry: each project gets name, repo path, description, dependency manifest, current branch, dirty state, and last activity. Add GET /v1/projects and POST /v1/projects/refresh endpoints. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p4-cross-project-queries",
        "phase": 4,
        "repo": "wrkflo-orchestrator",
        "description": "Add CLI and API examples for cross-project workspace queries so operators can inspect project registry cards, branches, dirty state, and dependency manifests across repos. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p5-cron-setup",
        "phase": 5,
        "repo": "dev-workspace",
        "description": "Create or improve dws-cron-setup so health checks, cleanup, and reliability cron entries are installed and verified idempotently. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p5-lint-ci",
        "phase": 5,
        "repo": "dev-workspace",
        "description": "Verify and improve .github/workflows/lint.yml to run shellcheck on all relevant shell scripts. Fix any shellcheck warnings in existing scripts. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
    {
        "id": "p5-launcher-header",
        "phase": 5,
        "repo": "dev-workspace",
        "description": "Improve the launcher header in dws-launcher.sh to show active tmux session count, orchestrator-aware health status summary, and disk usage on startup. Stage, commit, push.",
        "assigned": None,
        "status": "pending",
    },
]


def task_map_from_canonical():
    return {task["id"]: deepcopy(task) for task in CANONICAL_TASKS}


def load_queue():
    if QUEUE_PATH.exists():
        try:
            return json.loads(QUEUE_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            planner_log("warning: task-queue.json was invalid JSON; reseeding from canonical tasks")
    return {"tasks": []}


def save_queue(queue):
    tmp = QUEUE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(queue, indent=2) + "\n", encoding="utf-8")
    tmp.replace(QUEUE_PATH)


def load_state():
    if STATE_PATH.exists():
        try:
            return json.loads(STATE_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    return {"initialized": False, "monitor_offset": 0}


def save_state(state):
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    tmp.replace(STATE_PATH)


def merge_existing_status(tasks_by_id, existing_tasks):
    for existing in existing_tasks:
        task_id = existing.get("id")
        if task_id in tasks_by_id:
            for key in ("assigned", "status"):
                if key in existing and existing[key] is not None:
                    tasks_by_id[task_id][key] = existing[key]
        else:
            tasks_by_id[task_id] = existing


IDLE_RE = re.compile(r"\[monitor\] ([\w-]+): idle, looking for task")
DISPATCH_RE = re.compile(r"\[monitor\] dispatching to ([\w-]+):")


def complete_task_for_session(tasks, session):
    changed = False
    for task in tasks:
        if task.get("assigned") == session and task.get("status") == "in_progress":
            task["status"] = "completed"
            task["assigned"] = session
            changed = True
    return changed


def reconcile_from_monitor_log(tasks, state):
    if not MONITOR_LOG_PATH.exists():
        return []

    raw = MONITOR_LOG_PATH.read_text(encoding="utf-8", errors="replace")
    offset = min(state.get("monitor_offset", 0), len(raw))
    new_text = raw[offset:]
    state["monitor_offset"] = len(raw)
    if not new_text:
        return []

    task_by_id = {task["id"]: task for task in tasks}
    events = []
    for line in new_text.splitlines():
        idle_match = IDLE_RE.search(line)
        if idle_match:
            session = idle_match.group(1)
            if complete_task_for_session(tasks, session):
                events.append(f"Marked in-progress task complete for {session} after idle transition.")
            continue

        dispatch_match = DISPATCH_RE.search(line)
        if dispatch_match:
            session = dispatch_match.group(1)
            # The monitor itself updates queue assignment state; planner only records the event.
            events.append(f"Observed new dispatch for {session}.")
            continue

    return events


def ensure_required_pending_tasks(tasks):
    task_by_id = {task["id"]: task for task in tasks}

    def any_active(prefix):
        return any(
            task["id"].startswith(prefix) and task["status"] in {"pending", "in_progress"}
            for task in tasks
        )

    additions = []

    if not any_active("p1-") and task_by_id.get("p1-health-cli-doc-sync", {}).get("status") != "completed":
        task_by_id["p1-health-cli-doc-sync"]["status"] = "pending"
        task_by_id["p1-health-cli-doc-sync"]["assigned"] = None
        additions.append("Reopened Phase 1 follow-up because no active Phase 1 work remained.")

    if not any_active("p3-") and task_by_id.get("p3-foundry-callers", {}).get("status") != "completed":
        task_by_id["p3-foundry-callers"]["status"] = "pending"
        task_by_id["p3-foundry-callers"]["assigned"] = None
        additions.append("Reopened remaining Phase 3 cleanup because no active Phase 3 work remained.")

    if not any_active("p4-"):
        for task_id in ("p4-project-cards", "p4-cross-project-queries"):
            if task_by_id.get(task_id, {}).get("status") not in {"completed", "in_progress"}:
                task_by_id[task_id]["status"] = "pending"
                task_by_id[task_id]["assigned"] = None
        additions.append("Ensured Phase 4 backlog remains queued.")

    if not any_active("p5-"):
        for task_id in ("p5-cron-setup", "p5-lint-ci", "p5-launcher-header"):
            if task_by_id.get(task_id, {}).get("status") not in {"completed", "in_progress"}:
                task_by_id[task_id]["status"] = "pending"
                task_by_id[task_id]["assigned"] = None
        additions.append("Ensured Phase 5 backlog remains queued.")

    return list(task_by_id.values()), additions


def phase_summary(tasks):
    summary = {}
    for phase in range(0, 6):
        phase_tasks = [task for task in tasks if task["phase"] == phase]
        if not phase_tasks:
            continue
        counts = {"completed": 0, "in_progress": 0, "pending": 0}
        for task in phase_tasks:
            counts[task["status"]] = counts.get(task["status"], 0) + 1
        if counts["pending"] == 0 and counts["in_progress"] == 0:
            state = "done"
        elif counts["in_progress"] > 0:
            state = "in progress"
        else:
            state = "pending"
        summary[phase] = {"state": state, "counts": counts, "tasks": phase_tasks}
    return summary


def write_status(tasks, recent_events):
    summary = phase_summary(tasks)
    active = [task for task in tasks if task["status"] == "in_progress"]
    pending = [task for task in tasks if task["status"] == "pending"]
    completed = [task for task in tasks if task["status"] == "completed"]
    recent_monitor = []
    if MONITOR_LOG_PATH.exists():
        recent_monitor = MONITOR_LOG_PATH.read_text(encoding="utf-8", errors="replace").splitlines()[-12:]

    lines = [
        "# Planner Status",
        "",
        f"Updated: {utc_now()}",
        "",
        "## Phase Status",
    ]
    for phase in sorted(summary):
        phase_data = summary[phase]
        counts = phase_data["counts"]
        lines.append(
            f"- Phase {phase}: {phase_data['state']} "
            f"(completed {counts.get('completed', 0)}, in progress {counts.get('in_progress', 0)}, pending {counts.get('pending', 0)})"
        )

    lines.extend(["", "## Active Tasks"])
    if active:
        for task in sorted(active, key=lambda t: (t["phase"], t["id"])):
            lines.append(f"- {task['assigned']}: `{task['id']}` ({task['repo']})")
            lines.append(f"  {task['description']}")
    else:
        lines.append("- None")

    lines.extend(["", "## Pending Backlog"])
    if pending:
        for task in sorted(pending, key=lambda t: (t["phase"], t["id"])):
            lines.append(f"- `{task['id']}` ({task['repo']}, phase {task['phase']})")
            lines.append(f"  {task['description']}")
    else:
        lines.append("- None")

    lines.extend(["", "## Completed Highlights"])
    for task in sorted(completed, key=lambda t: (t["phase"], t["id"]))[:8]:
        owner = task["assigned"] or "unassigned"
        lines.append(f"- `{task['id']}` completed by {owner}")

    lines.extend(["", "## Recent Planner Decisions"])
    if recent_events:
        for event in recent_events:
            lines.append(f"- {event}")
    else:
        lines.append("- None")

    lines.extend(["", "## Recent Monitor Log"])
    if recent_monitor:
        for line in recent_monitor:
            lines.append(f"- {line}")
    else:
        lines.append("- No monitor output yet.")

    STATUS_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def sorted_tasks(tasks):
    return sorted(tasks, key=lambda task: (task["phase"], task["id"]))


def run_cycle():
    existing_queue = load_queue()
    state = load_state()
    tasks_by_id = task_map_from_canonical()
    merge_existing_status(tasks_by_id, existing_queue.get("tasks", []))
    tasks = sorted_tasks(list(tasks_by_id.values()))

    planner_events = []

    if not state.get("initialized", False):
        state["initialized"] = True
        state["monitor_offset"] = MONITOR_LOG_PATH.stat().st_size if MONITOR_LOG_PATH.exists() else 0
        planner_events.append("Initialized planner state from current queue and monitor-log position.")
    else:
        planner_events.extend(reconcile_from_monitor_log(tasks, state))

    tasks, additions = ensure_required_pending_tasks(tasks)
    planner_events.extend(additions)

    save_queue({"tasks": sorted_tasks(tasks)})
    save_state(state)
    write_status(tasks, planner_events)

    for event in planner_events:
        planner_log(event)


def main():
    while True:
        run_cycle()
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
