#!/usr/bin/env zsh
# global-sentinel-sync.sh — every run inspects the global-sentinel Terminal
# window and, when that Codex session is idle, sends a scoped coordination ping.

if [[ -z "${GLOBAL_SENTINEL_SYNC_LOGIN:-}" ]]; then
  /bin/zsh -lc "GLOBAL_SENTINEL_SYNC_LOGIN=1 '$0'"
  exit $?
fi

set -euo pipefail

WINDOW_MATCH="${WINDOW_MATCH:-global-sentinel}"
SYNC_NOTE="${SYNC_NOTE:-5-minute sync: stay inside ~/projects/global-sentinel only and leave .codex untouched. Reply with status, changed files, blockers, and the next smallest safe task. If the cross-project routing doc task is complete, inspect the current diff and tighten the next ambiguous routing example. Do not edit ~/dev-workspace.}"
LOG_FILE="${LOG_FILE:-/tmp/global-sentinel-sync.log}"

window_index=$(/usr/bin/osascript \
  -e 'on run argv' \
  -e 'set windowMatch to item 1 of argv' \
  -e 'tell application "Terminal"' \
  -e 'repeat with i from 1 to count of windows' \
  -e 'if (name of window i) contains windowMatch then return i as text' \
  -e 'end repeat' \
  -e 'end tell' \
  -e 'error "no matching Terminal window"' \
  -e 'end run' \
  -- "$WINDOW_MATCH")

capture=$(/usr/bin/osascript \
  -e "tell application \"Terminal\" to get contents of selected tab of window $window_index")

{
  printf '\n[%s] inspected %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$WINDOW_MATCH"
  printf '%s\n' "$capture" | tail -n 120
} >>"$LOG_FILE"

if printf '%s\n' "$capture" | tail -n 20 | grep -q 'Working'; then
  printf '%s skipped prompt; other Codex session is working\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE"
  exit 0
fi

/usr/bin/osascript \
  -e 'on run argv' \
  -e 'set windowNumber to item 1 of argv as integer' \
  -e 'set syncNote to item 2 of argv' \
  -e 'tell application "Terminal"' \
  -e 'activate' \
  -e 'set index of window windowNumber to 1' \
  -e 'do script (syncNote & return) in window windowNumber' \
  -e 'end tell' \
  -e 'end run' \
  -- "$window_index" "$SYNC_NOTE"

printf '%s sent sync to %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$WINDOW_MATCH" >>"$LOG_FILE"
