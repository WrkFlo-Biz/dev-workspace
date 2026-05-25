#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Skip in CI — this test requires tmux mock isolation
if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  printf "SKIP (CI): %s\n" "$(basename "$0")"
  exit 0
fi
SCRIPT="${ROOT}/scripts/dws-launcher.sh"
FIXTURE_ROOT=$(mktemp -d)
FAKE_BIN="${FIXTURE_ROOT}/bin"
QUEUE_PATH="${FIXTURE_ROOT}/task-queue.json"
HEALTH_LOG="/tmp/dws-health.log"
HEALTH_ALERT_LOG="/tmp/dws-health-alerts.log"
HEALTH_LOG_BACKUP="${FIXTURE_ROOT}/dws-health.log.bak"
HEALTH_ALERT_LOG_BACKUP="${FIXTURE_ROOT}/dws-health-alerts.log.bak"
ORIG_PATH="${PATH}"
REAL_TMUX_BIN="$(command -v tmux || true)"
REAL_TMUX_SOCKET=""

cleanup() {
  if [ -n "${REAL_TMUX_BIN:-}" ] && [ -n "${REAL_TMUX_SOCKET:-}" ]; then
    "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" kill-server >/dev/null 2>&1 || true
  fi

  if [ -f "$HEALTH_LOG_BACKUP" ]; then
    cp "$HEALTH_LOG_BACKUP" "$HEALTH_LOG"
  else
    rm -f -- "$HEALTH_LOG"
  fi

  if [ -f "$HEALTH_ALERT_LOG_BACKUP" ]; then
    cp "$HEALTH_ALERT_LOG_BACKUP" "$HEALTH_ALERT_LOG"
  else
    rm -f -- "$HEALTH_ALERT_LOG"
  fi

  rm -rf -- "$FIXTURE_ROOT"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf 'SKIP: %s\n' "$*"
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing output: $needle"
}

assert_not_contains() {
  local haystack="${1:-}" needle="${2:-}"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    fail "unexpected output: $needle"
  fi
}

strip_ansi() {
  sed -E 's/\x1B\[[0-9;]*m//g'
}

write_fake_command() {
  local name="$1" body="$2"
  local path="${FAKE_BIN}/${name}"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "$path"
}

install_real_tmux_wrapper() {
  REAL_TMUX_SOCKET="${FIXTURE_ROOT}/tmux-integration.sock"

  cat >"${FAKE_BIN}/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" "\$@"
EOF
  chmod +x "${FAKE_BIN}/tmux"
}

isolated_tmux_socket_available() {
  local probe_session="dws-probe-$$"

  [ -n "${REAL_TMUX_BIN:-}" ] || return 1
  [ -n "${REAL_TMUX_SOCKET:-}" ] || return 1

  if ! "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" new-session -d -s "${probe_session}" 'sleep 1' >/dev/null 2>&1; then
    return 1
  fi

  "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" kill-session -t "${probe_session}" >/dev/null 2>&1 || true
  "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" kill-server >/dev/null 2>&1 || true
  return 0
}

run_real_tmux_status_integration_test() {
  local integration_output integration_plain_output session_block

  if [ -z "${REAL_TMUX_BIN:-}" ]; then
    skip "tmux unavailable; skipping launcher integration test"
    return 0
  fi

  install_real_tmux_wrapper
  if ! isolated_tmux_socket_available; then
    skip "isolated tmux socket unavailable; skipping launcher integration test"
    return 0
  fi

  "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" new-session -d -s test-session-1 'sleep 300'
  "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" new-session -d -s test-session-2 'sleep 300'

  write_fake_command curl 'exit 1'

  write_fake_command tailscale 'if [ "${1:-}" = "status" ]; then
  printf "%s\n" "100.64.0.10   dev-workspace-vm      Wrk-Flo@  linux  -"
  exit 0
fi
if [ "${1:-}" = "ip" ] && [ "${2:-}" = "-4" ]; then
  printf "%s\n" "100.64.0.10"
  exit 0
fi
exit 1'

  integration_output=$(
    HOME="${FIXTURE_ROOT}/home" \
    PATH="${FAKE_BIN}:${ORIG_PATH}" \
    AZURE_OPENAI_API_KEY='' \
    DWS_LAUNCHER_INTERNAL_STATUS_ONLY=1 \
    DWS_STATUS_TOOL="${FIXTURE_ROOT}/missing-status.sh" \
    DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
    DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
    bash "$SCRIPT" status 2>&1
  )

  integration_plain_output=$(printf '%s\n' "$integration_output" | strip_ansi)
  session_block=$(printf '%s\n' "$integration_plain_output" | awk '
    /^  active sessions$/ { capture = 1; next }
    /^  projects$/ { exit }
    capture { print }
  ')

  assert_contains "$integration_plain_output" "orchestrator health API unavailable; using shell heuristics"
  assert_contains "$integration_plain_output" "sessions: 2 active"
  assert_contains "$integration_plain_output" "active sessions"
  assert_contains "$session_block" "test-session-1"
  assert_contains "$session_block" "test-session-2"
  assert_not_contains "$integration_plain_output" "no tmux sessions yet; start one from the project list below or use Plain shell (7)"

  "${REAL_TMUX_BIN}" -S "${REAL_TMUX_SOCKET}" kill-server >/dev/null 2>&1 || true
  REAL_TMUX_SOCKET=""
}

trap cleanup EXIT

mkdir -p "$FAKE_BIN" "${FIXTURE_ROOT}/home"

if [ -f "$HEALTH_LOG" ]; then
  cp "$HEALTH_LOG" "$HEALTH_LOG_BACKUP"
fi
if [ -f "$HEALTH_ALERT_LOG" ]; then
  cp "$HEALTH_ALERT_LOG" "$HEALTH_ALERT_LOG_BACKUP"
fi

cat >"$QUEUE_PATH" <<'EOF'
{
  "tasks": [
    {"status": "pending"},
    {"status": "in_progress"},
    {"status": "in_progress"},
    {"status": "completed"}
  ]
}
EOF

printf '%s\n' "2026-04-23 21:40:00 health: 7 ok, 0 fail" >"$HEALTH_LOG"
: >"$HEALTH_ALERT_LOG"

write_fake_command curl 'cat <<'\''EOF'\''
{"vm":{"hostname":"dev-workspace-vm","uptime":"up 1 hour","disk_percent":41,"memory_percent":37},"tailscale":{"connected":true,"ip":"100.64.0.10"},"sessions":["gs-5-4","orch-codex"],"projects":[{"name":"global-sentinel","branch":"main","dirty":false},{"name":"wrkflo-orchestrator","branch":"feature/queue","dirty":true}],"foundry_key":{"loaded":true}}
EOF'

write_fake_command tailscale 'if [ "${1:-}" = "ip" ] && [ "${2:-}" = "-4" ]; then
  printf "%s\n" "100.64.0.10"
  exit 0
fi
exit 1'

write_fake_command systemctl 'if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ] && [ "${3:-}" = "dws-task-monitor.service" ]; then
  printf "%s\n" "active"
  exit 0
fi
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show" ] && [ "${3:-}" = "dws-task-monitor.service" ] && [ "${4:-}" = "--property=SubState" ] && [ "${5:-}" = "--value" ]; then
  printf "%s\n" "running"
  exit 0
fi
exit 1'

write_fake_command df 'cat <<'\''EOF'\''
Filesystem     1024-blocks  Used Available Capacity Mounted on
/dev/root         1000000 410000    590000       41% /
EOF'

write_fake_command dws-health-check.sh 'exit 0'

output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  AZURE_OPENAI_API_KEY='' \
  DWS_LAUNCHER_INTERNAL_STATUS_ONLY=1 \
  DWS_STATUS_TOOL="${FIXTURE_ROOT}/missing-status.sh" \
  DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  bash "$SCRIPT" status 2>&1
)

plain_output=$(printf '%s\n' "$output" | strip_ansi)

assert_contains "$plain_output" "sessions: 2 active"
assert_contains "$plain_output" "tailnet:  100.64.0.10"
assert_contains "$plain_output" "monitor:  active (running)"
assert_contains "$plain_output" "health:   check=2026-04-23 21:40:00  result=7 ok, 0 fail"
assert_contains "$plain_output" "usage:    disk=41% used"
queue_line=$(printf '%s\n' "$plain_output" | awk '/queue:/ { print; exit }')
assert_contains "$queue_line" "queue:"
assert_contains "$queue_line" "pending=1"
assert_contains "$queue_line" "in_progress=2"
assert_contains "$queue_line" "completed=1"
assert_contains "$queue_line" "total=4"
assert_contains "$plain_output" "active sessions"
assert_contains "$plain_output" "wrkflo-orchestrator"
assert_contains "$plain_output" "OpenAI profiles unavailable: missing"
assert_contains "$plain_output" "OpenAI choices 1-6 and v stay disabled until AZURE_OPENAI_API_KEY is restored"
assert_contains "$plain_output" "fallback: Claude models 7-9, Claude Code CLI, or plain shell"

missing_env_output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  AZURE_OPENAI_API_KEY='' \
  DWS_LAUNCHER_INTERNAL_STATUS_ONLY=1 \
  DWS_LAUNCHER_ENV_PATH="${FIXTURE_ROOT}/missing-dws-env.sh" \
  DWS_STATUS_TOOL="${FIXTURE_ROOT}/missing-status.sh" \
  DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  bash "$SCRIPT" status 2>&1
)

missing_env_plain_output=$(printf '%s\n' "$missing_env_output" | strip_ansi)

assert_contains "$missing_env_plain_output" "sessions: 2 active"
assert_contains "$missing_env_plain_output" "tailnet:  100.64.0.10"
assert_contains "$missing_env_plain_output" "wrkflo-orchestrator"
assert_contains "$missing_env_plain_output" "OpenAI profiles unavailable: missing"
assert_contains "$missing_env_plain_output" "OpenAI choices 1-6 and v stay disabled until AZURE_OPENAI_API_KEY is restored"
assert_contains "$missing_env_plain_output" "fallback: Claude models 7-9, Claude Code CLI, or plain shell"

write_fake_command tailscale 'exit 1'

write_fake_command df 'exit 1'

fallback_output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  AZURE_OPENAI_API_KEY='' \
  DWS_LAUNCHER_INTERNAL_STATUS_ONLY=1 \
  DWS_STATUS_TOOL="${FIXTURE_ROOT}/missing-status.sh" \
  DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  bash "$SCRIPT" status 2>&1
)

fallback_plain_output=$(printf '%s\n' "$fallback_output" | strip_ansi)

assert_contains "$fallback_plain_output" "sessions: 2 active"
assert_contains "$fallback_plain_output" "tailnet:  100.64.0.10"
assert_contains "$fallback_plain_output" "usage:    disk=41% used"
assert_not_contains "$fallback_plain_output" "tailnet:  unavailable"
assert_not_contains "$fallback_plain_output" "usage:    disk=unavailable used"

write_fake_command curl 'cat <<'\''EOF'\''
{"vm":{"hostname":"dev-workspace-vm","uptime":"up 1 hour","disk_percent":41,"memory_percent":37},"tailscale":{"connected":false,"ip":"100.64.0.10"},"sessions":[],"projects":[],"foundry_key":{"loaded":false}}
EOF'

payload_down_output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  AZURE_OPENAI_API_KEY='' \
  DWS_LAUNCHER_INTERNAL_STATUS_ONLY=1 \
  DWS_STATUS_TOOL="${FIXTURE_ROOT}/missing-status.sh" \
  DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  bash "$SCRIPT" status 2>&1
)

payload_down_plain_output=$(printf '%s\n' "$payload_down_output" | strip_ansi)

assert_contains "$payload_down_plain_output" "tailnet:  down"
assert_contains "$payload_down_plain_output" "connected: no"
assert_contains "$payload_down_plain_output" "local-only mode: tmux sessions still work, but Mac and phone bridge features are unavailable"

write_fake_command curl 'exit 1'

write_fake_command tmux 'exit 1'

write_fake_command hostname 'if [ "${1:-}" = "-s" ]; then
  printf "%s\n" "dev-workspace-vm"
  exit 0
fi
printf "%s\n" "dev-workspace-vm.example.net"'

write_fake_command uptime 'if [ "${1:-}" = "-p" ]; then
  printf "%s\n" "up 5 minutes"
  exit 0
fi
printf "%s\n" " 00:05:00 up 5 minutes,  1 user,  load average: 0.10, 0.05, 0.01"'

write_fake_command free 'cat <<'\''EOF'\''
               total        used        free      shared  buff/cache   available
Mem:            16Gi       4.0Gi       8.0Gi       1.0Mi       4.0Gi        12Gi
Swap:             0B          0B          0B
EOF'

write_fake_command sudo 'exit 1'

shell_fallback_output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  AZURE_OPENAI_API_KEY='' \
  DWS_LAUNCHER_INTERNAL_STATUS_ONLY=1 \
  DWS_STATUS_TOOL="${FIXTURE_ROOT}/missing-status.sh" \
  DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  bash "$SCRIPT" status 2>&1
)

shell_fallback_plain_output=$(printf '%s\n' "$shell_fallback_output" | strip_ansi)

assert_contains "$shell_fallback_plain_output" "orchestrator health API unavailable; using shell heuristics"
assert_contains "$shell_fallback_plain_output" "sessions:"
assert_contains "$shell_fallback_plain_output" "health:   check=2026-04-23 21:40:00  result=7 ok, 0 fail  key=missing"
assert_contains "$shell_fallback_plain_output" "active sessions"
assert_contains "$shell_fallback_plain_output" "projects"
assert_contains "$shell_fallback_plain_output" "tailnet:  down"
assert_contains "$shell_fallback_plain_output" "(tailscale status unavailable)"
assert_contains "$shell_fallback_plain_output" "disk:   unavailable"
assert_contains "$shell_fallback_plain_output" "(none)"
assert_contains "$shell_fallback_plain_output" "no tmux sessions yet; start one from the project list below or use Plain shell (7)"
assert_contains "$shell_fallback_plain_output" "OpenAI profiles unavailable: missing"
assert_contains "$shell_fallback_plain_output" "OpenAI choices 1-6 and v stay disabled until AZURE_OPENAI_API_KEY is restored"
assert_contains "$shell_fallback_plain_output" "fallback: Claude models 7-9, Claude Code CLI, or plain shell"
assert_contains "$shell_fallback_plain_output" "local-only mode: tmux sessions still work, but Mac and phone bridge features are unavailable"

write_fake_command curl 'cat <<'\''EOF'\''
{"vm":{"hostname":"dev-workspace-vm","uptime":"up 1 hour","disk_percent":41,"memory_percent":37},"tailscale":{"connected":true,"ip":"100.64.0.10"},"sessions":["gs-5-4","orch-codex"],"projects":[{"name":"global-sentinel","branch":"main","dirty":false},{"name":"wrkflo-orchestrator","branch":"feature/queue","dirty":true}],"foundry_key":{"loaded":true}}
EOF'

write_fake_command broken-status 'printf "%s\n" "boom" >&2
exit 1'

tool_failure_output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  AZURE_OPENAI_API_KEY='' \
  DWS_STATUS_TOOL="${FAKE_BIN}/broken-status" \
  DWS_STATUS_TOOL_REPO="${FIXTURE_ROOT}/missing-status-repo.sh" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  bash "$SCRIPT" status 2>&1
)

tool_failure_plain_output=$(printf '%s\n' "$tool_failure_output" | strip_ansi)

assert_contains "$tool_failure_plain_output" "external status tool failed; falling back"
assert_contains "$tool_failure_plain_output" "wrkflo-orchestrator"

run_real_tmux_status_integration_test

printf 'PASS: dws launcher status header\n'
