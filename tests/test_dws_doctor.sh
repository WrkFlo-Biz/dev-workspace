#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-doctor.sh"
CRON_SETUP_SCRIPT="${REPO_ROOT}/bin/dws-cron-setup.sh"

ORIG_PATH="${PATH}"
ORIG_HOME="${HOME}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) fail "expected output to omit: $needle" ;;
    *) ;;
  esac
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

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-doctor-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  RUNTIME_ROOT="${FIXTURE_ROOT}/runtime"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export NO_COLOR=1

  mkdir -p "${FAKE_BIN}" "${RUNTIME_ROOT}" "${HOME}" "${FIXTURE_ROOT}/backups"

  export DWS_TEST_CRONTAB_PATH="${FIXTURE_ROOT}/crontab.txt"
  export DWS_BACKUP_ROOT="${FIXTURE_ROOT}/backups"
  export DWS_CLEANUP_STAMP_PATH="${RUNTIME_ROOT}/dws-cleanup.last-success"
  export DWS_LOG_ROTATE_CRON_LOG_PATH="${RUNTIME_ROOT}/log-rotate.log"
  export DWS_SESSION_CLEANUP_CRON_LOG_PATH="${RUNTIME_ROOT}/session-cleanup.log"
  export DWS_PLANNER_STATUS_PATH="${RUNTIME_ROOT}/planner-status.md"
  export DWS_PLANNER_STATE_PATH="${RUNTIME_ROOT}/planner-state.json"
  export DWS_PLANNER_LOG_PATH="${RUNTIME_ROOT}/planner-log.txt"
  export DWS_MONITOR_STATUS_PATH="${RUNTIME_ROOT}/monitor-status.json"
  export DWS_MONITOR_LOG_PATH="${RUNTIME_ROOT}/monitor-log.txt"
  export DWS_ORCHESTRATOR_MONITOR_LOG_PATH="${RUNTIME_ROOT}/orchestrator-monitor.log"
  export DWS_CRON_LOG_DIR="${RUNTIME_ROOT}"
  export DWS_HEALTH_CHECK_SCRIPT="${REPO_ROOT}/scripts/dws-health-check.sh"
  export DWS_CLEANUP_SCRIPT="${REPO_ROOT}/bin/dws-cleanup.sh"
  export DWS_STATUS_SCRIPT="${REPO_ROOT}/bin/dws-status.sh"
  export DWS_BACKUP_SCRIPT="${REPO_ROOT}/bin/dws-backup.sh"
  export DWS_CRON_SETUP_SCRIPT="${CRON_SETUP_SCRIPT}"
  export DWS_BACKUP_WARN_AGE_SECONDS=86400
  export DWS_BACKUP_FAIL_AGE_SECONDS=172800
  export DWS_CLEANUP_WARN_AGE_SECONDS=64800
  export DWS_CLEANUP_FAIL_AGE_SECONDS=129600
  export DWS_PLANNER_STALE_SECONDS=1200
  export DWS_PLANNER_LOG_STALE_SECONDS=3600
  export DWS_MONITOR_STALE_SECONDS=1200
  export DWS_MONITOR_LOG_STALE_SECONDS=3600

  : >"${DWS_TEST_CRONTAB_PATH}"

  write_fake_command df 'cat <<'\''EOF'\''
Filesystem     1024-blocks  Used Available Capacity Mounted on
/dev/root         1000000 40000    960000       40% /
EOF'

  write_fake_command free 'cat <<'\''EOF'\''
               total        used        free      shared  buff/cache   available
Mem:         1000000      200000      500000        1000      300000      700000
Swap:              0           0           0
EOF'

  # shellcheck disable=SC2016
  write_fake_command tailscale '
case "${1:-}" in
  status) exit 0 ;;
  ip)
    if [ "${2:-}" = "-4" ]; then
      printf "100.64.0.10\n"
      exit 0
    fi
    ;;
esac
exit 1'

  # shellcheck disable=SC2016
  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  printf "doctor|1\n"
  exit 0
fi
exit 1'

  # shellcheck disable=SC2016
  write_fake_command crontab '
if [ "${1:-}" = "-l" ]; then
  [ -f "${DWS_TEST_CRONTAB_PATH}" ] && cat "${DWS_TEST_CRONTAB_PATH}"
  exit 0
fi
exit 1'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset NO_COLOR \
    DWS_TEST_CRONTAB_PATH \
    DWS_BACKUP_ROOT \
    DWS_CLEANUP_STAMP_PATH \
    DWS_LOG_ROTATE_CRON_LOG_PATH \
    DWS_SESSION_CLEANUP_CRON_LOG_PATH \
    DWS_PLANNER_STATUS_PATH \
    DWS_PLANNER_STATE_PATH \
    DWS_PLANNER_LOG_PATH \
    DWS_MONITOR_STATUS_PATH \
    DWS_MONITOR_LOG_PATH \
    DWS_ORCHESTRATOR_MONITOR_LOG_PATH \
    DWS_CRON_LOG_DIR \
    DWS_HEALTH_CHECK_SCRIPT \
    DWS_CLEANUP_SCRIPT \
    DWS_STATUS_SCRIPT \
    DWS_BACKUP_SCRIPT \
    DWS_CRON_SETUP_SCRIPT \
    DWS_BACKUP_WARN_AGE_SECONDS \
    DWS_BACKUP_FAIL_AGE_SECONDS \
    DWS_CLEANUP_WARN_AGE_SECONDS \
    DWS_CLEANUP_FAIL_AGE_SECONDS \
    DWS_PLANNER_STALE_SECONDS \
    DWS_PLANNER_LOG_STALE_SECONDS \
    DWS_MONITOR_STALE_SECONDS \
    DWS_MONITOR_LOG_STALE_SECONDS

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

write_managed_crontab() {
  local block
  block=$(bash "${CRON_SETUP_SCRIPT}" --show)
  printf '%s\n' "$block" >"${DWS_TEST_CRONTAB_PATH}"
}

create_backup_snapshot() {
  local snapshot="${DWS_BACKUP_ROOT}/20260423T000000Z"

  mkdir -p "${snapshot}/meta"
  printf 'created_at=2026-04-23T00:00:00Z\n' >"${snapshot}/meta/summary.txt"
  ln -sfn "${snapshot}" "${DWS_BACKUP_ROOT}/latest"
}

test_doctor_passes_with_planner_fresh() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_managed_crontab
  create_backup_snapshot
  printf 'completed_at=2026-04-23T00:00:00Z\n' >"${DWS_CLEANUP_STAMP_PATH}"
  printf 'planner: healthy\n' >"${DWS_PLANNER_STATUS_PATH}"
  printf '{"phase":"idle"}\n' >"${DWS_PLANNER_STATE_PATH}"
  printf 'planner log entry\n' >"${DWS_PLANNER_LOG_PATH}"

  output=$(bash "${SCRIPT}" 2>&1)
  assert_contains "${output}" "PASS managed cron entries installed: dws-health-check, dws-log-rotate, dws-session-cleanup"
  assert_contains "${output}" "PASS last backup is "
  assert_contains "${output}" "PASS last cleanup is "
  assert_contains "${output}" "PASS planner artifacts fresh"
  assert_contains "${output}" "monitor artifacts not present"
  assert_not_contains "${output}" "FAIL "

  cleanup_fixture
  trap - EXIT
}

test_doctor_accepts_monitor_when_planner_missing() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_managed_crontab
  create_backup_snapshot
  cat >"${DWS_LOG_ROTATE_CRON_LOG_PATH}" <<'EOF'
removed temp     /tmp/placeholder.txt

Summary (apply)
  stale worktrees: 0
  tmux sessions:   0
  logs compressed: 0
  stale logs:      0
  temp files:      1
EOF
  printf '{"workers":{}}\n' >"${DWS_MONITOR_STATUS_PATH}"
  printf 'monitor heartbeat\n' >"${DWS_MONITOR_LOG_PATH}"
  printf 'orchestrator monitor heartbeat\n' >"${DWS_ORCHESTRATOR_MONITOR_LOG_PATH}"

  output=$(bash "${SCRIPT}" 2>&1)
  assert_contains "${output}" "WARN cleanup success stamp is missing; falling back to cron log activity"
  assert_contains "${output}" "PASS monitor artifacts fresh"
  assert_contains "${output}" "planner artifacts not present"
  assert_not_contains "${output}" "FAIL "

  cleanup_fixture
  trap - EXIT
}

test_doctor_fails_with_actionable_messages() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  create_backup_snapshot
  touch -d '4 days ago' "${DWS_BACKUP_ROOT}/20260423T000000Z/meta/summary.txt"
  printf 'planner: stale\n' >"${DWS_PLANNER_STATUS_PATH}"
  printf '{"phase":"stale"}\n' >"${DWS_PLANNER_STATE_PATH}"
  printf 'planner stopped\n' >"${DWS_PLANNER_LOG_PATH}"
  touch -d '3 days ago' "${DWS_PLANNER_STATUS_PATH}" "${DWS_PLANNER_STATE_PATH}" "${DWS_PLANNER_LOG_PATH}"

  if output=$(bash "${SCRIPT}" 2>&1); then
    fail "expected doctor to fail"
  fi

  assert_contains "${output}" "FAIL no crontab is installed; run ${CRON_SETUP_SCRIPT}"
  assert_contains "${output}" "FAIL last backup is "
  assert_contains "${output}" "run ${REPO_ROOT}/bin/dws-backup.sh backup"
  assert_contains "${output}" "FAIL no successful cleanup run found; run ${REPO_ROOT}/bin/dws-cleanup.sh"
  assert_contains "${output}" "FAIL planner artifacts stale"
  assert_contains "${output}" "run ${REPO_ROOT}/bin/dws-status.sh, tail -n 40 ${DWS_PLANNER_LOG_PATH}, and restart the planner tmux session if needed"

  cleanup_fixture
  trap - EXIT
}

test_doctor_passes_with_planner_fresh
test_doctor_accepts_monitor_when_planner_missing
test_doctor_fails_with_actionable_messages
printf 'ok\n'
