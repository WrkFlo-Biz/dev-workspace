#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-status.sh"
FIXTURE_ROOT=$(mktemp -d)
FAKE_BIN="${FIXTURE_ROOT}/bin"
QUEUE_PATH="${FIXTURE_ROOT}/task-queue.json"
HEALTH_LOG_PATH="${FIXTURE_ROOT}/dws-health.log"
ORIG_PATH="${PATH}"

cleanup() {
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

trap cleanup EXIT

mkdir -p "$FAKE_BIN" "${FIXTURE_ROOT}/home"

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

printf '%s\n' "2026-04-23 21:40:00 health: 7 ok, 0 fail" >"$HEALTH_LOG_PATH"

write_fake_command curl 'cat <<'\''EOF'\''
{"vm":{"hostname":"dev-workspace-vm","uptime":"up 1 hour","disk_percent":41,"memory_percent":37},"tailscale":{"connected":true,"ip":"100.64.0.10"},"sessions":["gs-5-4","orch-codex"],"projects":[{"name":"global-sentinel","branch":"main","dirty":false},{"name":"wrkflo-orchestrator","branch":"feature/queue","dirty":true}],"foundry_key":{"loaded":true}}
EOF'

output=$(
  HOME="${FIXTURE_ROOT}/home" \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  DWS_TASK_QUEUE_PATH="$QUEUE_PATH" \
  DWS_HEALTH_LOG_PATH="$HEALTH_LOG_PATH" \
  bash "$SCRIPT" 2>&1
)

plain_output=$(printf '%s\n' "$output" | strip_ansi)

assert_contains "$plain_output" "status: active_sessions=2 active  health_check=2026-04-23 21:40:00  health=7 ok, 0 fail"
assert_contains "$plain_output" "usage:  disk=41% used  queue=pending=1  in_progress=2  completed=1  total=4"
assert_contains "$plain_output" "orchestrator health API"
assert_contains "$plain_output" "wrkflo-orchestrator"

printf 'PASS: dws status header\n'
