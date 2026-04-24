#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
STATE_DIR="${DWS_STATE_DIR:-${REPO_ROOT}/.state}"
TASKS_DIR="${DWS_TASKS_DIR:-${STATE_DIR}/tasks}"
RESULTS_DIR="${DWS_RESULTS_DIR:-${STATE_DIR}/results}"
TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-${STATE_DIR}/task-queue.json}"
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-${HOME}/projects}"

usage() {
  cat <<'EOF'
usage: dws-worker-exec.sh TASK_ID

Read .state/tasks/TASK_ID.json, run the task command in its repo directory,
capture stdout/stderr to .state/results/TASK_ID.log, write
.state/results/TASK_ID.json, and update .state/task-queue.json to completed or
failed.

Environment:
  DWS_STATE_DIR         Override the state root (default: repo .state/)
  DWS_TASKS_DIR         Override the task JSON directory
  DWS_RESULTS_DIR       Override the results directory
  DWS_TASK_QUEUE_PATH   Override the queue JSON path
  DWS_PROJECTS_ROOT     Override the projects root for relative repo names
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ $# -eq 1 ] || die "usage: dws-worker-exec.sh TASK_ID"
need_cmd python3 || die "python3 is required"

python3 - "$1" "$TASKS_DIR" "$RESULTS_DIR" "$TASK_QUEUE_PATH" "$PROJECTS_ROOT" <<'PY'
from __future__ import annotations

import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


TASK_ID = sys.argv[1]
TASKS_DIR = Path(sys.argv[2]).expanduser()
RESULTS_DIR = Path(sys.argv[3]).expanduser()
TASK_QUEUE_PATH = Path(sys.argv[4]).expanduser()
PROJECTS_ROOT = Path(sys.argv[5]).expanduser()


def die(message: str, *, exit_code: int = 1) -> "NoReturn":
    print(message, file=sys.stderr)
    raise SystemExit(exit_code)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path: Path, *, label: str) -> object:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        die(f"{label} not found: {path}")
    except json.JSONDecodeError as exc:
        die(f"{label} is not valid JSON: {path} ({exc})")


def write_json_atomic(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def require_object(payload: object, *, label: str) -> dict[str, object]:
    if not isinstance(payload, dict):
        die(f"{label} must contain a top-level JSON object")
    return payload


def require_string(payload: dict[str, object], field: str, *, allow_empty: bool = False) -> str:
    value = payload.get(field)
    if not isinstance(value, str):
        die(f"task field '{field}' must be a string")
    if not allow_empty and not value.strip():
        die(f"task field '{field}' must not be empty")
    return value


def parse_timeout(payload: dict[str, object]) -> float:
    raw = payload.get("timeout")
    if isinstance(raw, bool) or raw is None:
        die("task field 'timeout' must be a positive number")

    if isinstance(raw, (int, float)):
        timeout = float(raw)
    elif isinstance(raw, str):
        try:
            timeout = float(raw.strip())
        except ValueError:
            die(f"task field 'timeout' must be numeric: {raw}")
    else:
        die("task field 'timeout' must be numeric")

    if not math.isfinite(timeout) or timeout <= 0:
        die("task field 'timeout' must be greater than zero")
    return timeout


def resolve_repo_dir(repo: str) -> Path:
    repo_text = repo.strip()
    repo_path = Path(repo_text).expanduser()

    if repo_text.startswith("~") or repo_path.is_absolute():
        candidate = repo_path
    else:
        relative_parts = Path(repo_text).parts
        if any(part == ".." for part in relative_parts):
            die(f"relative repo paths must not traverse parents: {repo_text}")
        candidate = PROJECTS_ROOT / repo_text

    candidate = candidate.resolve()
    if not candidate.is_dir():
        die(f"repo directory not found: {candidate}")
    return candidate


def load_queue(path: Path) -> dict[str, object]:
    payload = require_object(load_json(path, label="queue file"), label="queue file")
    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        die("queue file must contain a top-level 'tasks' array")
    return payload


def normalize_exit_code(value: int) -> int:
    if value < 0:
        return 128 + abs(value)
    return value


if not re.fullmatch(r"[A-Za-z0-9._-]+", TASK_ID):
    die(f"task id contains unsupported characters: {TASK_ID}")

task_path = TASKS_DIR / f"{TASK_ID}.json"
task_payload = require_object(load_json(task_path, label="task file"), label="task file")

task_id = require_string(task_payload, "id")
repo = require_string(task_payload, "repo")
command = require_string(task_payload, "command")
model = require_string(task_payload, "model", allow_empty=True)
timeout = parse_timeout(task_payload)

if task_id != TASK_ID:
    die(f"task id mismatch: expected {TASK_ID}, found {task_id}")

repo_dir = resolve_repo_dir(repo)
queue_payload = load_queue(TASK_QUEUE_PATH)
queue_tasks = queue_payload["tasks"]

if not any(isinstance(task, dict) and str(task.get("id", "")) == task_id for task in queue_tasks):
    die(f"task id not found in queue: {task_id}")

RESULTS_DIR.mkdir(parents=True, exist_ok=True)
log_path = RESULTS_DIR / f"{task_id}.log"
result_path = RESULTS_DIR / f"{task_id}.json"

started = time.monotonic()
exit_code = 127

with log_path.open("w", encoding="utf-8") as log_handle:
    try:
        completed = subprocess.run(
            command,
            shell=True,
            executable="/bin/bash",
            cwd=str(repo_dir),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            text=True,
            env=os.environ.copy(),
        )
        exit_code = normalize_exit_code(completed.returncode)
    except subprocess.TimeoutExpired:
        exit_code = 124
        log_handle.write(f"\n[dws-worker-exec] command timed out after {timeout:g}s\n")
    except OSError as exc:
        exit_code = 127
        log_handle.write(f"\n[dws-worker-exec] failed to start command: {exc}\n")

duration = round(time.monotonic() - started, 3)
timestamp = utc_now()
status = "completed" if exit_code == 0 else "failed"

result_payload = {
    "id": task_id,
    "repo": repo,
    "command": command,
    "model": model,
    "timeout": timeout,
    "exit_code": exit_code,
    "duration": duration,
    "timestamp": timestamp,
    "status": status,
    "log_path": str(log_path),
}
write_json_atomic(result_path, result_payload)

queue_payload = load_queue(TASK_QUEUE_PATH)
queue_tasks = queue_payload["tasks"]
updated = False
for queue_task in queue_tasks:
    if isinstance(queue_task, dict) and str(queue_task.get("id", "")) == task_id:
        queue_task["status"] = status
        updated = True

if not updated:
    die(f"task id not found in queue: {task_id}")

write_json_atomic(TASK_QUEUE_PATH, queue_payload)

summary = f"{task_id}: {status} (exit {exit_code}, {duration:.3f}s)"
stream = sys.stdout if exit_code == 0 else sys.stderr
print(summary, file=stream)
raise SystemExit(exit_code)
PY
