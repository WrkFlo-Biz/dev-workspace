#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SESSION_TOOL="${ROOT}/scripts/dws-sessions.sh"
SOCKET="dws-test-$$"
SESSION_NAME="recovery-test"
CRASHED_SESSION="compacted-test"
META_DIR=$(mktemp -d)
MONITOR_LOG=$(mktemp)

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$META_DIR" "$MONITOR_LOG"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing output: $needle"
}

assert_matches() {
  local haystack="${1:-}" pattern="${2:-}"
  printf '%s\n' "$haystack" | grep -E -- "$pattern" >/dev/null || fail "missing pattern: $pattern"
}

trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || fail "tmux is required"
[ -x "$SESSION_TOOL" ] || fail "missing session tool: $SESSION_TOOL"

export DWS_TMUX_SOCKET="$SOCKET"
export DWS_SESSION_META_DIR="$META_DIR"
export DWS_MONITOR_LOG="$MONITOR_LOG"

TASK_TEXT="Persist last project, profile, and task metadata across compaction"
printf '%s\n' "2026-04-23T22:00:00Z [monitor] dispatching to ${SESSION_NAME} (repo=dev-workspace): ${TASK_TEXT}" >"$MONITOR_LOG"

tmux -L "$SOCKET" new-session -d -s "$SESSION_NAME" "bash -lc 'printf \"Working (1m)\\n\"; exec bash -l'"
tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_project "dev-workspace"
tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_model "5-4"
tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_profile "foundry-5_4"

initial_output=$("$SESSION_TOOL" show "$SESSION_NAME")
assert_contains "$initial_output" "project        dev-workspace"
assert_contains "$initial_output" "profile        5-4"
assert_contains "$initial_output" "last task      ${TASK_TEXT}"

META_FILE="${META_DIR}/${SESSION_NAME}.tsv"
[ -f "$META_FILE" ] || fail "metadata file was not created"
grep -F $'project\tdev-workspace' "$META_FILE" >/dev/null || fail "project metadata missing"
grep -F $'profile\tfoundry-5_4' "$META_FILE" >/dev/null || fail "profile metadata missing"
grep -F $'task\t'"${TASK_TEXT}" "$META_FILE" >/dev/null || fail "task metadata missing"

tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_project ""
tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_model ""
tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_profile ""
tmux -L "$SOCKET" set-option -t "$SESSION_NAME" -q @dws_task ""
: >"$MONITOR_LOG"
tmux -L "$SOCKET" respawn-pane -k -t "$SESSION_NAME" "exec bash -l"

recovered_output=$("$SESSION_TOOL" show "$SESSION_NAME")
assert_contains "$recovered_output" "project        dev-workspace"
assert_contains "$recovered_output" "profile        5-4"
assert_contains "$recovered_output" "last task      ${TASK_TEXT}"
assert_contains "$recovered_output" "monitor task   ${TASK_TEXT}"

CRASH_TASK="Relaunch the compacted dev-workspace worker with the same profile"
printf '%s\n' "2026-04-23T22:05:00Z [monitor] dispatching to ${CRASHED_SESSION} (repo=dev-workspace): ${CRASH_TASK}" >>"$MONITOR_LOG"
tmux -L "$SOCKET" new-session -d -s "$CRASHED_SESSION" "bash -lc 'printf \"Compact task: high demand\\nSession ended. [r]estart / [q]uit:\\n\"; exec bash -l'"
tmux -L "$SOCKET" set-option -t "$CRASHED_SESSION" -q @dws_project "dev-workspace"
tmux -L "$SOCKET" set-option -t "$CRASHED_SESSION" -q @dws_model "5-4"
tmux -L "$SOCKET" set-option -t "$CRASHED_SESSION" -q @dws_profile "foundry-5_4"

crashed_output=$("$SESSION_TOOL" show "$CRASHED_SESSION")
assert_contains "$crashed_output" "state          crashed"
assert_contains "$crashed_output" "last task      ${CRASH_TASK}"
assert_contains "$crashed_output" "monitor task   ${CRASH_TASK}"
assert_matches "$crashed_output" '^crash marker   (compact task|high demand|session ended)$'
assert_contains "$crashed_output" "one-command    dws-sessions.sh relaunch ${CRASHED_SESSION}"
assert_contains "$crashed_output" "quick launch   bash ${ROOT}/scripts/dws-quick.sh dws 5-4"

relaunch_output=$("$SESSION_TOOL" relaunch "$CRASHED_SESSION")
assert_contains "$relaunch_output" "relaunching ${CRASHED_SESSION} -> dev-workspace (5-4)"
assert_contains "$relaunch_output" "last task: ${CRASH_TASK}"
assert_contains "$relaunch_output" "bash ${ROOT}/scripts/dws-quick.sh dws 5-4"

"$SESSION_TOOL" kill "$SESSION_NAME" >/dev/null
"$SESSION_TOOL" kill "$CRASHED_SESSION" >/dev/null
[ ! -e "$META_FILE" ] || fail "metadata file was not removed on kill"

printf 'PASS: dws session metadata recovery\n'
