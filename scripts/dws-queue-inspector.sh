#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-${REPO_ROOT}/.state/task-queue.json}"
MONITOR_LOG_PATH="${DWS_QUEUE_INSPECTOR_LOG_PATH:-/var/log/dws/monitor.log}"
JSON_OUTPUT=0

usage() {
  cat <<'EOF'
usage: dws-queue-inspector.sh [--json] [--queue PATH] [--log PATH]

Inspect the live task queue and monitor log to summarize task history,
retry or delay reasons, reassignment signals, completion timing, and
worker utilization.

Options:
  --json        emit machine-readable JSON
  --queue PATH  queue file (default: repo .state/task-queue.json)
  --log PATH    monitor log (default: /var/log/dws/monitor.log)
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
    --log)
      [ $# -ge 2 ] || die "--log requires a path"
      MONITOR_LOG_PATH="$2"
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
[ -r "$MONITOR_LOG_PATH" ] || die "monitor log not readable: $MONITOR_LOG_PATH"

python3 - "$TASK_QUEUE_PATH" "$MONITOR_LOG_PATH" "$JSON_OUTPUT" <<'PY'
from __future__ import annotations

import gzip
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from textwrap import shorten

TASK_QUEUE_PATH = sys.argv[1]
MONITOR_LOG_PATH = sys.argv[2]
JSON_OUTPUT = sys.argv[3] == "1"

TIMED_LINE_RE = re.compile(r"^(?P<clock>\d{2}:\d{2}:\d{2}) \[monitor\] (?P<body>.*)$")
WORKER_LINE_RE = re.compile(r"^(?P<worker>[\w-]+): (?P<msg>.+)$")
DISPATCH_RE = re.compile(r"^dispatching to (?P<worker>[\w-]+) \(repo=(?P<repo>[^)]+)\): (?P<desc>.+)$")
CYCLE_START_RE = re.compile(r"^--- check cycle \d{2}:\d{2}:\d{2} ---$")
CYCLE_DONE_RE = re.compile(r"^--- cycle done: (?P<working>\d+) working, (?P<pending>\d+) pending tasks ---$")


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_json(path: str) -> object:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        die(f"queue file not found: {path}")
    except json.JSONDecodeError as exc:
        die(f"queue file is not valid JSON: {path} ({exc})")


def read_lines(path: str) -> list[str]:
    opener = gzip.open if path.endswith(".gz") else open
    try:
        with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()
    except FileNotFoundError:
        die(f"monitor log not found: {path}")


def parse_clock_seconds(clock: str) -> int:
    hours, minutes, seconds = (int(part) for part in clock.split(":"))
    return hours * 3600 + minutes * 60 + seconds


def format_timestamp(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.strftime("%Y-%m-%d %H:%M:%S UTC")


def format_duration(seconds: float | None) -> str:
    if seconds is None:
        return "n/a"
    total = int(round(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def worker_sort_key(name: str) -> tuple[int, str]:
    if name.startswith("dws-"):
        return (0, name)
    if name.startswith("worker-"):
        return (1, name)
    return (2, name)


def status_sort_key(item: tuple[str, int]) -> tuple[int, str]:
    return (-item[1], item[0])


def is_worker(name: str) -> bool:
    return bool(name) and name != "orchestrator"


def parse_log_entries(path: str) -> tuple[list[dict[str, object]], dict[str, object]]:
    lines = read_lines(path)
    timestamped: list[dict[str, object]] = []

    for lineno, line in enumerate(lines, start=1):
        match = TIMED_LINE_RE.match(line)
        if not match:
            continue
        clock = match.group("clock")
        timestamped.append(
            {
                "lineno": lineno,
                "clock": clock,
                "seconds": parse_clock_seconds(clock),
                "body": match.group("body"),
            }
        )

    if not timestamped:
        return [], {"start": None, "end": None, "day_rollovers": 0}

    rollovers = 0
    previous_seconds = None
    for entry in timestamped:
        current_seconds = int(entry["seconds"])
        if previous_seconds is not None and current_seconds < previous_seconds:
            rollovers += 1
        previous_seconds = current_seconds

    last_date = datetime.utcfromtimestamp(os.path.getmtime(path)).date()
    current_date = last_date - timedelta(days=rollovers)
    previous_seconds = None

    for entry in timestamped:
        current_seconds = int(entry["seconds"])
        if previous_seconds is not None and current_seconds < previous_seconds:
            current_date += timedelta(days=1)
        entry["timestamp"] = datetime.combine(current_date, datetime.min.time()) + timedelta(
            seconds=current_seconds
        )
        previous_seconds = current_seconds

    return (
        timestamped,
        {
            "start": timestamped[0]["timestamp"],
            "end": timestamped[-1]["timestamp"],
            "day_rollovers": rollovers,
        },
    )


queue_doc = read_json(TASK_QUEUE_PATH)
if not isinstance(queue_doc, dict):
    die("queue file must contain a top-level JSON object")

queue_tasks_raw = queue_doc.get("tasks", [])
if not isinstance(queue_tasks_raw, list):
    die("queue file must contain a top-level 'tasks' array")

queue_tasks: list[dict[str, object]] = []
tasks_by_repo: dict[str, list[dict[str, object]]] = defaultdict(list)
queue_status_counts: Counter[str] = Counter()
queue_workers: set[str] = set()

for index, raw_task in enumerate(queue_tasks_raw):
    if not isinstance(raw_task, dict):
        continue

    task = {
        "index": index,
        "id": str(raw_task.get("id", f"task-{index + 1}")),
        "repo": str(raw_task.get("repo", "")),
        "description": str(raw_task.get("description", "")),
        "status": str(raw_task.get("status", "unknown")) or "unknown",
        "assigned": str(raw_task.get("assigned", "")),
        "phase": raw_task.get("phase"),
    }
    queue_tasks.append(task)
    tasks_by_repo[str(task["repo"])].append(task)
    queue_status_counts[str(task["status"])] += 1
    if is_worker(str(task["assigned"])):
        queue_workers.add(str(task["assigned"]))


def resolve_task_meta(repo: str, logged_description: str) -> dict[str, object]:
    description = logged_description.strip()
    truncated = description.endswith("...")
    prefix = description[:-3] if truncated else description
    candidates: list[dict[str, object]] = []
    repo_tasks = tasks_by_repo.get(repo, [])

    if prefix:
        if truncated:
            candidates = [task for task in repo_tasks if str(task["description"]).startswith(prefix)]
        else:
            candidates = [task for task in repo_tasks if str(task["description"]) == prefix]
            if not candidates:
                candidates = [task for task in repo_tasks if str(task["description"]).startswith(prefix)]

    if not candidates and prefix:
        short_prefix = prefix[:60]
        candidates = [task for task in repo_tasks if str(task["description"]).startswith(short_prefix)]

    candidate_ids = [str(task["id"]) for task in candidates]
    queue_matches = len(candidate_ids)
    queue_statuses = Counter(str(task["status"]) for task in candidates)
    queue_assigned_workers = sorted(
        {str(task["assigned"]) for task in candidates if is_worker(str(task["assigned"]))},
        key=worker_sort_key,
    )

    return {
        "signature": f"{repo}|{prefix or description}",
        "task_id": candidate_ids[0] if queue_matches == 1 else None,
        "repo": repo,
        "description_prefix": prefix or description,
        "display_description": description,
        "ambiguous": queue_matches != 1,
        "queue_match_count": queue_matches,
        "candidate_ids": candidate_ids,
        "queue_statuses": dict(sorted(queue_statuses.items())),
        "queue_assigned_workers": queue_assigned_workers,
    }


entries, window = parse_log_entries(MONITOR_LOG_PATH)

worker_stats: dict[str, dict[str, int]] = defaultdict(
    lambda: {
        "dispatches": 0,
        "completed_assignments": 0,
        "retry_events": 0,
        "rate_limit_events": 0,
        "observed_cycles": 0,
        "working_cycles": 0,
        "idle_cycles": 0,
        "no_task_cycles": 0,
        "rate_limited_cycles": 0,
        "blocked_cycles": 0,
    }
)
task_histories: dict[str, dict[str, object]] = {}
active_by_worker: dict[str, dict[str, object]] = {}
instances_by_signature: dict[str, list[dict[str, object]]] = defaultdict(list)
known_workers = set(queue_workers)
all_completion_seconds: list[float] = []


def cycle_state_for_message(message: str) -> str | None:
    if message == "working (ok)" or message.startswith("confirmed Working"):
        return "working"
    if message == "idle":
        return "idle"
    if message == "no tasks available":
        return "no_task"
    if message == "rate limited, will retry next cycle":
        return "rate_limited"
    if (
        message == "FAILED to start"
        or "retrying Enter" in message
        or message.startswith("COMPACTED")
        or message.startswith("CRASHED")
        or message.startswith("DEAD")
        or message.startswith("UNKNOWN")
        or message == "relaunch may have failed"
    ):
        return "blocked"
    return None


def issue_reason_for_message(message: str) -> str | None:
    if message.startswith("COMPACTED"):
        return "compacted"
    if message.startswith("CRASHED"):
        return "crashed"
    if message.startswith("DEAD"):
        return "dead"
    if message.startswith("UNKNOWN"):
        return "unknown"
    if message == "relaunch may have failed":
        return "relaunch_maybe_failed"
    if message == "FAILED to start":
        return "failed_to_start"
    return None


def ensure_history(meta: dict[str, object]) -> dict[str, object]:
    signature = str(meta["signature"])
    history = task_histories.get(signature)
    if history is not None:
        if not history["candidate_ids"] and meta["candidate_ids"]:
            history["task_id"] = meta["task_id"]
            history["candidate_ids"] = list(meta["candidate_ids"])
            history["queue_match_count"] = meta["queue_match_count"]
            history["queue_statuses"] = dict(meta["queue_statuses"])
            history["queue_assigned_workers"] = list(meta["queue_assigned_workers"])
            history["ambiguous"] = meta["ambiguous"]
        return history

    history = {
        "signature": signature,
        "task_id": meta["task_id"],
        "repo": meta["repo"],
        "description_prefix": meta["description_prefix"],
        "display_description": meta["display_description"],
        "ambiguous": meta["ambiguous"],
        "queue_match_count": meta["queue_match_count"],
        "candidate_ids": list(meta["candidate_ids"]),
        "queue_statuses": dict(meta["queue_statuses"]),
        "queue_assigned_workers": list(meta["queue_assigned_workers"]),
        "dispatches": 0,
        "completed_assignments": 0,
        "completion_seconds": [],
        "retry_events": [],
        "delay_events": [],
        "issue_events": [],
        "reassignments": [],
        "workers_seen": set(),
    }
    task_histories[signature] = history
    return history


def new_instance(history: dict[str, object], worker: str, timestamp: datetime) -> dict[str, object]:
    instance = {
        "signature": history["signature"],
        "history": history,
        "worker": worker,
        "dispatch_ts": timestamp,
        "closed": False,
        "pending_reassign": False,
        "last_block_reason": None,
        "last_retry_event": None,
    }
    history["dispatches"] += 1
    history["workers_seen"].add(worker)
    worker_stats[worker]["dispatches"] += 1
    instances_by_signature[str(history["signature"])].append(instance)
    return instance


def close_instance(instance: dict[str, object], *, completed: bool = False, closed_at: datetime | None = None) -> None:
    if instance.get("closed"):
        return

    instance["closed"] = True
    if not completed or closed_at is None:
        return

    history = instance["history"]
    duration = (closed_at - instance["dispatch_ts"]).total_seconds()
    if duration < 0:
        return
    instance["duration_seconds"] = duration
    history["completed_assignments"] += 1
    history["completion_seconds"].append(duration)
    worker_stats[instance["worker"]]["completed_assignments"] += 1
    all_completion_seconds.append(duration)


def flush_cycle(states: dict[str, str]) -> None:
    for worker, state in states.items():
        if not is_worker(worker):
            continue
        stats = worker_stats[worker]
        stats["observed_cycles"] += 1
        if state == "working":
            stats["working_cycles"] += 1
        elif state == "idle":
            stats["idle_cycles"] += 1
        elif state == "no_task":
            stats["no_task_cycles"] += 1
        elif state == "rate_limited":
            stats["rate_limited_cycles"] += 1
        elif state == "blocked":
            stats["blocked_cycles"] += 1


current_cycle_states: dict[str, str] = {}

for entry in entries:
    timestamp = entry["timestamp"]
    body = str(entry["body"])

    if CYCLE_START_RE.match(body):
        flush_cycle(current_cycle_states)
        current_cycle_states = {}
        continue

    if CYCLE_DONE_RE.match(body):
        flush_cycle(current_cycle_states)
        current_cycle_states = {}
        continue

    dispatch_match = DISPATCH_RE.match(body)
    if dispatch_match:
        worker = dispatch_match.group("worker")
        repo = dispatch_match.group("repo")
        description = dispatch_match.group("desc")
        if is_worker(worker):
            known_workers.add(worker)

        meta = resolve_task_meta(repo, description)
        history = ensure_history(meta)
        previous_instance = active_by_worker.get(worker)
        if previous_instance is not None:
            close_instance(previous_instance)

        instance = new_instance(history, worker, timestamp)
        active_by_worker[worker] = instance
        current_cycle_states[worker] = "working"

        for candidate in reversed(instances_by_signature[str(history["signature"])]):
            if candidate is instance or candidate.get("closed") or candidate["worker"] == worker:
                continue
            if not candidate.get("pending_reassign"):
                continue
            if candidate.get("last_block_reason") in (None, "rate_limited"):
                continue

            history["reassignments"].append(
                {
                    "timestamp": timestamp,
                    "from_worker": candidate["worker"],
                    "to_worker": worker,
                    "reason": candidate["last_block_reason"],
                    "inferred": True,
                }
            )
            close_instance(candidate)
            if active_by_worker.get(candidate["worker"]) is candidate:
                del active_by_worker[candidate["worker"]]
            break
        continue

    worker_match = WORKER_LINE_RE.match(body)
    if not worker_match:
        continue

    worker = worker_match.group("worker")
    message = worker_match.group("msg")
    if is_worker(worker):
        known_workers.add(worker)

    cycle_state = cycle_state_for_message(message)
    if cycle_state is not None:
        current_cycle_states[worker] = cycle_state

    instance = active_by_worker.get(worker)
    if instance is None:
        continue

    history = instance["history"]
    history["workers_seen"].add(worker)

    if message == "marked previous task completed":
        close_instance(instance, completed=True, closed_at=timestamp)
        del active_by_worker[worker]
        continue

    if "retrying Enter" in message:
        history["retry_events"].append(
            {
                "timestamp": timestamp,
                "worker": worker,
                "reason": "not_working",
                "outcome": "pending",
            }
        )
        instance["last_retry_event"] = history["retry_events"][-1]
        instance["last_block_reason"] = "not_working"
        worker_stats[worker]["retry_events"] += 1
        continue

    if message == "confirmed Working on retry":
        retry_event = instance.get("last_retry_event")
        if retry_event is not None and retry_event.get("outcome") == "pending":
            retry_event["outcome"] = "recovered_on_retry"
            retry_event["resolved_at"] = timestamp
        instance["pending_reassign"] = False
        instance["last_block_reason"] = None
        continue

    if message == "confirmed Working" or message == "working (ok)":
        instance["pending_reassign"] = False
        if instance.get("last_block_reason") == "rate_limited":
            instance["last_block_reason"] = None
        continue

    if message == "rate limited, will retry next cycle":
        history["delay_events"].append(
            {
                "timestamp": timestamp,
                "worker": worker,
                "reason": "rate_limited",
            }
        )
        instance["last_block_reason"] = "rate_limited"
        worker_stats[worker]["rate_limit_events"] += 1
        continue

    issue_reason = issue_reason_for_message(message)
    if issue_reason is None:
        continue

    if issue_reason == "failed_to_start" and instance.get("last_retry_event") is not None:
        retry_event = instance["last_retry_event"]
        if retry_event.get("outcome") == "pending":
            retry_event["outcome"] = "failed_to_start"
            retry_event["resolved_at"] = timestamp
    else:
        history["issue_events"].append(
            {
                "timestamp": timestamp,
                "worker": worker,
                "reason": issue_reason,
            }
        )

    instance["pending_reassign"] = issue_reason != "rate_limited"
    instance["last_block_reason"] = issue_reason


flush_cycle(current_cycle_states)


def history_issue_score(history: dict[str, object]) -> int:
    return (
        len(history["retry_events"])
        + len(history["delay_events"])
        + len(history["issue_events"])
        + len(history["reassignments"])
    )


def serialize_retry_event(event: dict[str, object]) -> dict[str, object]:
    payload = {
        "time": format_timestamp(event.get("timestamp")),
        "worker": event.get("worker"),
        "reason": event.get("reason"),
        "outcome": event.get("outcome"),
    }
    if event.get("resolved_at") is not None:
        payload["resolved_at"] = format_timestamp(event.get("resolved_at"))
    return payload


def serialize_simple_event(event: dict[str, object]) -> dict[str, object]:
    payload = {
        "time": format_timestamp(event.get("timestamp")),
        "worker": event.get("worker"),
        "reason": event.get("reason"),
    }
    return payload


def serialize_reassignment(event: dict[str, object]) -> dict[str, object]:
    return {
        "time": format_timestamp(event.get("timestamp")),
        "from_worker": event.get("from_worker"),
        "to_worker": event.get("to_worker"),
        "reason": event.get("reason"),
        "inferred": bool(event.get("inferred")),
    }


def serialize_history(history: dict[str, object]) -> dict[str, object]:
    average_seconds = None
    if history["completion_seconds"]:
        average_seconds = sum(history["completion_seconds"]) / len(history["completion_seconds"])

    combined_events: list[dict[str, object]] = []
    for event in history["issue_events"]:
        combined_events.append(
            {
                "timestamp": event["timestamp"],
                "type": "issue",
                "worker": event["worker"],
                "reason": event["reason"],
            }
        )
    for event in history["retry_events"]:
        combined_events.append(
            {
                "timestamp": event["timestamp"],
                "type": "retry",
                "worker": event["worker"],
                "reason": event["reason"],
                "outcome": event["outcome"],
            }
        )
    for event in history["delay_events"]:
        combined_events.append(
            {
                "timestamp": event["timestamp"],
                "type": "delay",
                "worker": event["worker"],
                "reason": event["reason"],
            }
        )
    for event in history["reassignments"]:
        combined_events.append(
            {
                "timestamp": event["timestamp"],
                "type": "reassignment",
                "from_worker": event["from_worker"],
                "to_worker": event["to_worker"],
                "reason": event["reason"],
                "inferred": bool(event["inferred"]),
            }
        )

    combined_events.sort(key=lambda item: item["timestamp"])

    serialized_events: list[dict[str, object]] = []
    for event in combined_events:
        payload = dict(event)
        payload["time"] = format_timestamp(payload.pop("timestamp"))
        serialized_events.append(payload)

    return {
        "task_ref": history["task_id"] or history["signature"],
        "task_id": history["task_id"],
        "repo": history["repo"],
        "display_description": history["display_description"],
        "description_prefix": history["description_prefix"],
        "ambiguous": bool(history["ambiguous"]),
        "queue_match_count": history["queue_match_count"],
        "candidate_task_ids": list(history["candidate_ids"]),
        "queue_statuses": dict(history["queue_statuses"]),
        "queue_assigned_workers": list(history["queue_assigned_workers"]),
        "dispatches": history["dispatches"],
        "completed_assignments": history["completed_assignments"],
        "average_completion_seconds": average_seconds,
        "average_completion_human": format_duration(average_seconds),
        "retry_events": [serialize_retry_event(event) for event in history["retry_events"]],
        "delay_events": [serialize_simple_event(event) for event in history["delay_events"]],
        "issue_events": [serialize_simple_event(event) for event in history["issue_events"]],
        "reassignments": [serialize_reassignment(event) for event in history["reassignments"]],
        "workers_seen": sorted(history["workers_seen"], key=worker_sort_key),
        "events": serialized_events,
    }


sorted_workers = sorted(
    {worker for worker in known_workers if is_worker(worker)},
    key=worker_sort_key,
)

worker_utilization = []
for worker in sorted_workers:
    stats = worker_stats[worker]
    observed_cycles = stats["observed_cycles"]
    utilization_ratio = (
        stats["working_cycles"] / observed_cycles if observed_cycles else None
    )
    worker_utilization.append(
        {
            "worker": worker,
            "observed_cycles": observed_cycles,
            "working_cycles": stats["working_cycles"],
            "idle_cycles": stats["idle_cycles"],
            "no_task_cycles": stats["no_task_cycles"],
            "rate_limited_cycles": stats["rate_limited_cycles"],
            "blocked_cycles": stats["blocked_cycles"],
            "dispatches": stats["dispatches"],
            "completed_assignments": stats["completed_assignments"],
            "retry_events": stats["retry_events"],
            "rate_limit_events": stats["rate_limit_events"],
            "utilization_ratio": utilization_ratio,
            "utilization_percent": None if utilization_ratio is None else utilization_ratio * 100.0,
        }
    )

rate_limit_events_by_worker = {
    worker: worker_stats[worker]["rate_limit_events"]
    for worker in sorted_workers
    if worker_stats[worker]["rate_limit_events"] > 0
}

average_completion_seconds = None
if all_completion_seconds:
    average_completion_seconds = sum(all_completion_seconds) / len(all_completion_seconds)

interesting_histories = [
    serialize_history(history)
    for history in sorted(
        task_histories.values(),
        key=lambda item: (
            -history_issue_score(item),
            str(item["task_id"] or item["display_description"]),
        ),
    )
    if history_issue_score(history) > 0
]

result = {
    "queue_path": TASK_QUEUE_PATH,
    "monitor_log_path": MONITOR_LOG_PATH,
    "window": {
        "start": format_timestamp(window["start"]),
        "end": format_timestamp(window["end"]),
        "day_rollovers": window["day_rollovers"],
    },
    "tasks_by_status": dict(sorted(queue_status_counts.items(), key=status_sort_key)),
    "task_total": len(queue_tasks),
    "retry_history": interesting_histories,
    "rate_limit_events_by_worker": rate_limit_events_by_worker,
    "average_task_completion": {
        "seconds": average_completion_seconds,
        "human": format_duration(average_completion_seconds),
        "samples": len(all_completion_seconds),
    },
    "worker_utilization": worker_utilization,
    "notes": [
        "Task history is grouped by repo and description prefix when the monitor log cannot uniquely resolve a queue task ID.",
        "Completion timing is computed only for assignments whose dispatch and completion both appear in the inspected log.",
        "Worker utilization is based on each worker's final observed state within a monitor cycle.",
    ],
}

if JSON_OUTPUT:
    print(json.dumps(result, indent=2, sort_keys=False))
    raise SystemExit(0)


def print_section(title: str) -> None:
    print(title)


print(f"queue: {TASK_QUEUE_PATH}")
print(f"monitor log: {MONITOR_LOG_PATH}")
if window["start"] is not None:
    print(
        "window: "
        f"{format_timestamp(window['start'])} -> {format_timestamp(window['end'])} "
        f"({window['day_rollovers']} day rollovers inferred from log clock)"
    )
else:
    print("window: no timestamped monitor lines found")

print()
print_section("Tasks by Status")
print(f"  total: {len(queue_tasks)}")
for status, count in sorted(queue_status_counts.items(), key=status_sort_key):
    print(f"  {status}: {count}")

print()
print_section("Average Task Completion Time")
if average_completion_seconds is None:
    print("  unavailable: no dispatch/completion pairs were fully observed in the inspected log")
else:
    print(
        f"  {format_duration(average_completion_seconds)} "
        f"across {len(all_completion_seconds)} observed completions"
    )

print()
print_section("Rate-Limit Events by Worker")
if rate_limit_events_by_worker:
    for worker, count in rate_limit_events_by_worker.items():
        print(f"  {worker}: {count}")
else:
    print("  none")

print()
print_section("Worker Utilization Summary")
header = (
    "  {worker:<10} {util:>6} {work:>6} {idle:>6} {none:>6} "
    "{limit:>6} {block:>6} {disp:>6} {done:>6} {retry:>6}"
)
print(
    header.format(
        worker="worker",
        util="util%",
        work="work",
        idle="idle",
        none="none",
        limit="limit",
        block="block",
        disp="disp",
        done="done",
        retry="retry",
    )
)
for row in worker_utilization:
    util = "n/a" if row["utilization_percent"] is None else f"{row['utilization_percent']:.1f}"
    print(
        header.format(
            worker=row["worker"],
            util=util,
            work=row["working_cycles"],
            idle=row["idle_cycles"],
            none=row["no_task_cycles"],
            limit=row["rate_limited_cycles"],
            block=row["blocked_cycles"],
            disp=row["dispatches"],
            done=row["completed_assignments"],
            retry=row["retry_events"],
        )
    )

print()
print_section("Retry/Delay/Reassignment History")
if not interesting_histories:
    print("  no retry, delay, reassignment, or worker-issue events matched to an observable task")
else:
    for history in interesting_histories:
        label = history["task_id"] or f"{history['repo']} :: {history['display_description']}"
        print(f"  {shorten(label, width=104, placeholder='...')}")
        if history["task_id"]:
            print(f"    queue match: unique task ID {history['task_id']}")
        elif history["queue_match_count"] > 1:
            print(
                f"    queue match: ambiguous across {history['queue_match_count']} current queue tasks"
            )
        else:
            print("    queue match: not found in the current queue snapshot")
        print(
            f"    observed: {history['dispatches']} dispatches, "
            f"{history['completed_assignments']} completions"
        )
        for event in history["events"]:
            if event["type"] == "retry":
                line = (
                    f"    {event['time']} retry {event['worker']}: "
                    f"{event['reason']} -> {event['outcome']}"
                )
            elif event["type"] == "delay":
                line = f"    {event['time']} delay {event['worker']}: {event['reason']}"
            elif event["type"] == "issue":
                line = f"    {event['time']} issue {event['worker']}: {event['reason']}"
            else:
                inferred = " (inferred)" if event.get("inferred") else ""
                line = (
                    f"    {event['time']} reassigned {event['from_worker']} -> "
                    f"{event['to_worker']}: {event['reason']}{inferred}"
                )
            print(line)

print()
print_section("Notes")
for note in result["notes"]:
    print(f"  - {note}")
PY
