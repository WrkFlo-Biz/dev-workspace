#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/dws-worker-exec.sh"

ORIG_HOME="${HOME}"
ORIG_PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-}"
ORIG_STATE_DIR="${DWS_STATE_DIR:-}"
ORIG_TASK_QUEUE_PATH="${DWS_TASK_QUEUE_PATH:-}"
ORIG_TASKS_DIR="${DWS_TASKS_DIR:-}"
ORIG_RESULTS_DIR="${DWS_RESULTS_DIR:-}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

json_field() {
  local path="$1" field="$2"
  python3 - "$path" "$field" <<'PY'
from __future__ import annotations

import json
import sys

path = sys.argv[1]
field = sys.argv[2]

with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)

for part in field.split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
PY
}

queue_status() {
  local task_id="$1"
  python3 - "${QUEUE_PATH}" "$task_id" <<'PY'
from __future__ import annotations

import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

for task in payload["tasks"]:
    if isinstance(task, dict) and str(task.get("id", "")) == sys.argv[2]:
        print(task.get("status", ""))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

write_task_json() {
  local task_id="$1" repo="$2" command="$3" model="$4" timeout="$5"
  python3 - "${DWS_TASKS_DIR}/${task_id}.json" "$task_id" "$repo" "$command" "$model" "$timeout" <<'PY'
from __future__ import annotations

import json
import sys

path, task_id, repo, command, model, timeout = sys.argv[1:]
payload = {
    "id": task_id,
    "repo": repo,
    "command": command,
    "model": model,
    "timeout": float(timeout) if "." in timeout else int(timeout),
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

write_queue_json() {
  local primary_id="$1" secondary_id="$2"
  python3 - "${QUEUE_PATH}" "$primary_id" "$secondary_id" <<'PY'
from __future__ import annotations

import json
import sys

payload = {
    "tasks": [
        {"id": sys.argv[2], "repo": "sample-repo", "status": "pending"},
        {"id": sys.argv[3], "repo": "sample-repo", "status": "pending"},
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

cleanup_fixture() {
  export HOME="${ORIG_HOME}"

  if [ -n "${ORIG_PROJECTS_ROOT}" ]; then
    export DWS_PROJECTS_ROOT="${ORIG_PROJECTS_ROOT}"
  else
    unset DWS_PROJECTS_ROOT
  fi

  if [ -n "${ORIG_STATE_DIR}" ]; then
    export DWS_STATE_DIR="${ORIG_STATE_DIR}"
  else
    unset DWS_STATE_DIR
  fi

  if [ -n "${ORIG_TASK_QUEUE_PATH}" ]; then
    export DWS_TASK_QUEUE_PATH="${ORIG_TASK_QUEUE_PATH}"
  else
    unset DWS_TASK_QUEUE_PATH
  fi

  if [ -n "${ORIG_TASKS_DIR}" ]; then
    export DWS_TASKS_DIR="${ORIG_TASKS_DIR}"
  else
    unset DWS_TASKS_DIR
  fi

  if [ -n "${ORIG_RESULTS_DIR}" ]; then
    export DWS_RESULTS_DIR="${ORIG_RESULTS_DIR}"
  else
    unset DWS_RESULTS_DIR
  fi

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-worker-exec-test.XXXXXX")
  export HOME="${FIXTURE_ROOT}/home"
  export DWS_PROJECTS_ROOT="${FIXTURE_ROOT}/projects"
  export DWS_STATE_DIR="${FIXTURE_ROOT}/state"
  export DWS_TASKS_DIR="${DWS_STATE_DIR}/tasks"
  export DWS_RESULTS_DIR="${DWS_STATE_DIR}/results"
  export DWS_TASK_QUEUE_PATH="${DWS_STATE_DIR}/task-queue.json"

  QUEUE_PATH="${DWS_TASK_QUEUE_PATH}"
  SAMPLE_REPO="${DWS_PROJECTS_ROOT}/sample-repo"

  mkdir -p "${HOME}" "${DWS_TASKS_DIR}" "${SAMPLE_REPO}"
  printf 'repo marker\n' >"${SAMPLE_REPO}/repo-marker.txt"
}

test_worker_exec_records_success_results() {
  local output task_id other_id log_path result_path

  make_fixture
  trap cleanup_fixture EXIT

  task_id="task-success"
  other_id="task-other"
  write_queue_json "$task_id" "$other_id"
  write_task_json \
    "$task_id" \
    "sample-repo" \
    "pwd; printf 'stdout ok\\n'; printf 'stderr ok\\n' >&2; [ -f repo-marker.txt ]" \
    "5-4" \
    "5"

  output=$(bash "${SCRIPT}" "$task_id" 2>&1)
  log_path="${DWS_RESULTS_DIR}/${task_id}.log"
  result_path="${DWS_RESULTS_DIR}/${task_id}.json"

  assert_contains "${output}" "${task_id}: completed (exit 0"
  assert_contains "$(cat "${log_path}")" "${SAMPLE_REPO}"
  assert_contains "$(cat "${log_path}")" "stdout ok"
  assert_contains "$(cat "${log_path}")" "stderr ok"
  [ -f "${result_path}" ] || fail "expected result JSON: ${result_path}"
  [ "$(json_field "${result_path}" "exit_code")" = "0" ] || fail "expected exit_code=0"
  [ "$(json_field "${result_path}" "status")" = "completed" ] || fail "expected completed status in result"
  [ "$(queue_status "${task_id}")" = "completed" ] || fail "expected queue status completed"
  [ "$(queue_status "${other_id}")" = "pending" ] || fail "expected unrelated queue entry to stay pending"
  assert_contains "$(json_field "${result_path}" "timestamp")" "T"

  cleanup_fixture
  trap - EXIT
}

test_worker_exec_records_nonzero_exit_codes() {
  local output status task_id other_id log_path result_path

  make_fixture
  trap cleanup_fixture EXIT

  task_id="task-failure"
  other_id="task-other"
  write_queue_json "$task_id" "$other_id"
  write_task_json \
    "$task_id" \
    "sample-repo" \
    "printf 'stdout bad\\n'; printf 'stderr bad\\n' >&2; exit 7" \
    "codex" \
    "5"

  set +e
  output=$(bash "${SCRIPT}" "$task_id" 2>&1)
  status=$?
  set -e

  log_path="${DWS_RESULTS_DIR}/${task_id}.log"
  result_path="${DWS_RESULTS_DIR}/${task_id}.json"

  [ "${status}" -eq 7 ] || fail "expected exit status 7, got ${status}"
  assert_contains "${output}" "${task_id}: failed (exit 7"
  assert_contains "$(cat "${log_path}")" "stdout bad"
  assert_contains "$(cat "${log_path}")" "stderr bad"
  [ "$(json_field "${result_path}" "exit_code")" = "7" ] || fail "expected exit_code=7"
  [ "$(json_field "${result_path}" "status")" = "failed" ] || fail "expected failed status in result"
  [ "$(queue_status "${task_id}")" = "failed" ] || fail "expected queue status failed"
  [ "$(queue_status "${other_id}")" = "pending" ] || fail "expected unrelated queue entry to stay pending"

  cleanup_fixture
  trap - EXIT
}

test_worker_exec_marks_timeouts_as_failed() {
  local output status task_id log_path result_path

  make_fixture
  trap cleanup_fixture EXIT

  task_id="task-timeout"
  write_queue_json "$task_id" "task-other"
  write_task_json \
    "$task_id" \
    "sample-repo" \
    "sleep 2" \
    "mini" \
    "1"

  set +e
  output=$(bash "${SCRIPT}" "$task_id" 2>&1)
  status=$?
  set -e

  log_path="${DWS_RESULTS_DIR}/${task_id}.log"
  result_path="${DWS_RESULTS_DIR}/${task_id}.json"

  [ "${status}" -eq 124 ] || fail "expected exit status 124, got ${status}"
  assert_contains "${output}" "${task_id}: failed (exit 124"
  assert_contains "$(cat "${log_path}")" "command timed out after 1s"
  [ "$(json_field "${result_path}" "exit_code")" = "124" ] || fail "expected exit_code=124"
  [ "$(json_field "${result_path}" "status")" = "failed" ] || fail "expected failed status in result"
  [ "$(queue_status "${task_id}")" = "failed" ] || fail "expected queue status failed"

  cleanup_fixture
  trap - EXIT
}

test_worker_exec_records_success_results
test_worker_exec_records_nonzero_exit_codes
test_worker_exec_marks_timeouts_as_failed

printf 'PASS: %s\n' "$(basename "$0")"
