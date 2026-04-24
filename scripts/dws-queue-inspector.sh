#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-${REPO_ROOT}/.state/task-queue.json}"
JSON_OUTPUT=0

usage() {
  cat <<'EOF'
usage: dws-queue-inspector.sh [--json] [--queue PATH]

Inspect .state/task-queue.json and summarize:
  - tasks by status
  - per-worker assignment counts
  - overall and per-worker completion rates

Options:
  --json        emit machine-readable JSON
  --queue PATH  queue file path (default: repo .state/task-queue.json)
  -h, --help    show this help
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      JSON_OUTPUT=1
      ;;
    --queue)
      [ $# -ge 2 ] || die "--queue requires a path"
      TASK_QUEUE_PATH="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

need_cmd python3 || die "python3 is required"
[ -r "$TASK_QUEUE_PATH" ] || die "queue file not readable: $TASK_QUEUE_PATH"

python3 - "$TASK_QUEUE_PATH" "$JSON_OUTPUT" <<'PY'
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict

TASK_QUEUE_PATH = sys.argv[1]
JSON_OUTPUT = sys.argv[2] == "1"


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_queue(path: str) -> list[dict[str, object]]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        die(f"queue file not found: {path}")
    except json.JSONDecodeError as exc:
        die(f"queue file is not valid JSON: {path} ({exc})")

    if not isinstance(payload, dict):
        die("queue file must contain a top-level JSON object")

    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        die("queue file must contain a top-level 'tasks' array")

    normalized: list[dict[str, object]] = []
    for index, raw_task in enumerate(tasks):
        if not isinstance(raw_task, dict):
            continue
        assigned_raw = raw_task.get("assigned")
        status_raw = raw_task.get("status", "unknown")
        normalized.append(
            {
                "id": str(raw_task.get("id", f"task-{index + 1}")),
                "status": "unknown" if status_raw is None else (str(status_raw) or "unknown"),
                "assigned": "" if assigned_raw is None else str(assigned_raw).strip(),
            }
        )
    return normalized


def worker_sort_key(name: str) -> tuple[int, str]:
    if name.startswith("dws-"):
        return (0, name)
    if name.startswith("worker-"):
        return (1, name)
    if name:
        return (2, name)
    return (3, name)


def percent(numerator: int, denominator: int) -> float | None:
    if denominator <= 0:
        return None
    return (numerator / denominator) * 100.0


tasks = load_queue(TASK_QUEUE_PATH)
total_tasks = len(tasks)
status_counts: Counter[str] = Counter()
worker_counts: dict[str, Counter[str]] = defaultdict(Counter)
completed_statuses = {"completed", "done"}

for task in tasks:
    status = str(task["status"])
    worker = str(task["assigned"])
    status_counts[status] += 1
    if worker:
        worker_counts[worker]["assigned"] += 1
        if status in completed_statuses:
            worker_counts[worker]["completed"] += 1
        else:
            worker_counts[worker]["open"] += 1

completed_tasks = sum(count for status, count in status_counts.items() if status in completed_statuses)
not_completed_tasks = total_tasks - completed_tasks
unassigned_tasks = sum(1 for task in tasks if not str(task["assigned"]))
overall_completion_rate = percent(completed_tasks, total_tasks)

workers = []
for worker in sorted(worker_counts, key=worker_sort_key):
    assigned = worker_counts[worker]["assigned"]
    completed = worker_counts[worker]["completed"]
    not_completed = worker_counts[worker]["open"]
    workers.append(
        {
            "worker": worker,
            "assigned": assigned,
            "completed": completed,
            "not_completed": not_completed,
            "completion_rate_percent": percent(completed, assigned),
        }
    )

result = {
    "queue_path": TASK_QUEUE_PATH,
    "task_total": total_tasks,
    "tasks_by_status": dict(sorted(status_counts.items(), key=lambda item: (-item[1], item[0]))),
    "completion": {
        "completed_tasks": completed_tasks,
        "not_completed_tasks": not_completed_tasks,
        "unassigned_tasks": unassigned_tasks,
        "completion_rate_percent": overall_completion_rate,
    },
    "workers": workers,
}

if JSON_OUTPUT:
    print(json.dumps(result, indent=2, sort_keys=False))
    raise SystemExit(0)

print(f"queue: {TASK_QUEUE_PATH}")
print()
print("Tasks by Status")
print(f"  total: {total_tasks}")
for status, count in result["tasks_by_status"].items():
    print(f"  {status}: {count}")

print()
print("Completion")
if overall_completion_rate is None:
    print("  completed: 0/0 (n/a)")
else:
    print(f"  completed: {completed_tasks}/{total_tasks} ({overall_completion_rate:.1f}%)")
print(f"  not completed: {not_completed_tasks}")
print(f"  unassigned: {unassigned_tasks}")

print()
print("Per-Worker Assignment Counts")
if not workers:
    print("  none")
else:
    print(f"  {'worker':<10} {'assigned':>8} {'completed':>9} {'pending':>8} {'rate%':>7}")
    for row in workers:
        rate = "n/a" if row["completion_rate_percent"] is None else f"{row['completion_rate_percent']:.1f}"
        print(
            f"  {row['worker']:<10} {row['assigned']:>8} {row['completed']:>9} "
            f"{row['not_completed']:>8} {rate:>7}"
        )
PY
