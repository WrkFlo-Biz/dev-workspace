#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-sessions-init.sh"
SOCKET="dws-init-test-$$"
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-sessions-init.XXXXXX")

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  unset DWS_TMUX_SOCKET DWS_PROJECTS_ROOT DWS_SESSION_INIT_MONITOR_SCRIPT DWS_SESSION_INIT_TIMEOUT_SECONDS
  rm -rf -- "${FIXTURE_ROOT}"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing output: $needle"
}

assert_equals() {
  local expected="${1:-}" actual="${2:-}" label="${3:-value}"
  [ "$expected" = "$actual" ] || fail "${label}: expected '${expected}', got '${actual}'"
}

pane_path() {
  tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_current_path}' | sed -n '1p'
}

pane_start_command() {
  tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_start_command}' | sed -n '1p'
}

session_option() {
  tmux -L "$SOCKET" show-options -t "$1" 2>/dev/null | awk -v key="$2" '$1 == key { print $2; exit }'
}

trap cleanup EXIT

command -v tmux >/dev/null 2>&1 || fail "tmux is required"
[ -x "$SCRIPT" ] || fail "missing init script: $SCRIPT"

export HOME="${FIXTURE_ROOT}/home"
export PATH="${FIXTURE_ROOT}/bin:${ORIG_PATH}"
export DWS_TMUX_SOCKET="${SOCKET}"
export DWS_PROJECTS_ROOT="${HOME}/projects"
export DWS_SESSION_INIT_MONITOR_SCRIPT="${HOME}/bin/task-monitor.sh"
export DWS_SESSION_INIT_TIMEOUT_SECONDS=5

mkdir -p \
  "${FIXTURE_ROOT}/bin" \
  "${HOME}/bin" \
  "${HOME}/projects/dev-workspace" \
  "${HOME}/projects/wrkflo-orchestrator"

cat >"${FIXTURE_ROOT}/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '  gpt-5.4 xhigh · %s\n' "$PWD"
printf '› ready\n'
exec sleep 300
EOF
chmod +x "${FIXTURE_ROOT}/bin/codex"

cat >"${HOME}/bin/task-monitor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s [monitor] monitor online\n' "$(date '+%H:%M:%S')"
printf 'status written: 0 done, 0 active, 0 pending\n'
exec sleep 300
EOF
chmod +x "${HOME}/bin/task-monitor.sh"

output=$(bash "$SCRIPT")
assert_contains "$output" "created dws-a (codex)"
assert_contains "$output" "created orchestrator (codex)"
assert_contains "$output" "created monitor (monitor)"
assert_contains "$output" "verified dws-a (sleep)"
assert_contains "$output" "verified monitor (sleep)"

session_count=$(tmux -L "$SOCKET" list-sessions -F '#{session_name}' | wc -l | tr -d ' ')
assert_equals "10" "$session_count" "session count"

assert_equals "${HOME}/projects/dev-workspace" "$(pane_path dws-a)" "dws-a cwd"
assert_equals "${HOME}/projects/wrkflo-orchestrator" "$(pane_path orchestrator)" "orchestrator cwd"
assert_equals "${HOME}/projects/dev-workspace" "$(pane_path monitor)" "monitor cwd"

assert_contains "$(pane_start_command dws-a)" "cd '${HOME}/projects/dev-workspace'; exec codex --profile 'foundry-5_4'"
assert_contains "$(pane_start_command orchestrator)" "cd '${HOME}/projects/wrkflo-orchestrator'; exec codex --profile 'foundry-5_4'"
assert_contains "$(pane_start_command monitor)" "exec '${HOME}/bin/task-monitor.sh'"

assert_equals "dev-workspace" "$(session_option dws-a @dws_project)" "dws-a project metadata"
assert_equals "5-4" "$(session_option dws-a @dws_model)" "dws-a model metadata"
assert_equals "foundry-5_4" "$(session_option dws-a @dws_profile)" "dws-a profile metadata"
assert_equals "wrkflo-orchestrator" "$(session_option orchestrator @dws_project)" "orchestrator project metadata"

rerun_output=$(bash "$SCRIPT")
assert_contains "$rerun_output" "reused dws-a (codex)"
assert_contains "$rerun_output" "reused orchestrator (codex)"
assert_contains "$rerun_output" "reused monitor (monitor)"

session_count_after=$(tmux -L "$SOCKET" list-sessions -F '#{session_name}' | wc -l | tr -d ' ')
assert_equals "10" "$session_count_after" "session count after rerun"

printf 'PASS: dws sessions init\n'
