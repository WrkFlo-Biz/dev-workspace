#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-motd.sh"
FIXTURE_ROOT=$(mktemp -d)
FAKE_BIN="${FIXTURE_ROOT}/bin"
QUEUE_PATH="${FIXTURE_ROOT}/task-queue.json"
BACKUP_ROOT="${FIXTURE_ROOT}/backups"
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

mkdir -p "${FAKE_BIN}" "${BACKUP_ROOT}/20260423T000000Z/meta"

cat >"${QUEUE_PATH}" <<'EOF'
{
  "tasks": [
    {"status": "pending"},
    {"status": "in_progress"},
    {"status": "active"},
    {"status": "completed"},
    {"status": "done"}
  ]
}
EOF

printf 'created_at=2026-04-23T00:00:00Z\n' >"${BACKUP_ROOT}/20260423T000000Z/meta/summary.txt"
ln -sfn "${BACKUP_ROOT}/20260423T000000Z" "${BACKUP_ROOT}/latest"

write_fake_command tailscale 'case "${1:-}" in
  status)
    if [ "${2:-}" = "--json" ]; then
      cat <<'\''EOF'\''
{"Self":{"TailscaleIPs":["100.64.0.10"]},"Peer":{"node-a":{"Online":true},"node-b":{"Online":false},"node-c":{"Online":true}}}
EOF
    fi
    ;;
  ip)
    printf '\''100.64.0.10\n'\''
    ;;
esac'

write_fake_command tmux 'if [ "${1:-}" = "list-sessions" ]; then
  cat <<'\''EOF'\''
gs-5-4|1|global-sentinel|/tmp/global-sentinel
orch-codex|0|wrkflo-orchestrator|/tmp/wrkflo-orchestrator
EOF
fi'

write_fake_command df 'case "${1:-}" in
  -Pk)
    cat <<'\''EOF'\''
Filesystem     1024-blocks    Used Available Capacity Mounted on
/dev/root         1000000  410000    590000       41% /
EOF
    ;;
  -Ph)
    cat <<'\''EOF'\''
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       1.0T  410G  590G  41% /
EOF
    ;;
esac'

write_fake_command free 'case "${1:-}" in
  -h)
    cat <<'\''EOF'\''
              total        used        free      shared  buff/cache   available
Mem:           16Gi       5.9Gi       8.0Gi       500Mi       2.1Gi        10Gi
Swap:          2.0Gi          0B       2.0Gi
EOF
    ;;
  *)
    cat <<'\''EOF'\''
              total        used        free      shared  buff/cache   available
Mem:          16000        5920        8000         500        2080       10080
Swap:          2048           0        2048
EOF
    ;;
esac'

write_fake_command uptime 'if [ "${1:-}" = "-p" ]; then
  printf '\''up 1 hour, 12 minutes\n'\''
else
  printf '\'' 10:00:00 up 1:12, 1 user, load average: 0.10, 0.20, 0.30\n'\''
fi'

output=$(
  NO_COLOR=1 \
  PATH="${FAKE_BIN}:${ORIG_PATH}" \
  DWS_TASK_QUEUE_PATH="${QUEUE_PATH}" \
  DWS_BACKUP_ROOT="${BACKUP_ROOT}" \
  DWS_MOTD_NOW_EPOCH="1776949200" \
  DWS_MOTD_NOW_LABEL="2026-04-23 13:00:00 UTC" \
  bash "${SCRIPT}" 2>&1
)

assert_contains "${output}" "uptime:   up 1 hour, 12 minutes"
assert_contains "${output}" "tailnet:  100.64.0.10  2 clients online"
assert_contains "${output}" "usage:    disk=41% (410G/1.0T)  mem=37% (5.9Gi/16Gi)"
assert_contains "${output}" "queue:    pending=1  active=2  done=2  total=5"
assert_contains "${output}" "backup:   2026-04-23 00:00:00 UTC (13h ago)"
assert_contains "${output}" "Tmux Sessions (2)"
assert_contains "${output}" "gs-5-4           global-sentinel              attached"
assert_contains "${output}" "orch-codex       wrkflo-orchestrator          detached"

printf 'PASS: dws motd summary\n'
