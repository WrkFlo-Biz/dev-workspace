#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-alerting.sh"

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
    *) fail "expected output to contain: ${needle}" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) fail "expected output to omit: ${needle}" ;;
    *) ;;
  esac
}

assert_file_contains() {
  local path="$1" needle="$2"

  [ -f "$path" ] || fail "expected file to exist: ${path}"
  assert_contains "$(cat "$path")" "$needle"
}

write_fake_command() {
  local name="$1" body="$2"
  local path="${FAKE_BIN}/${name}"

  cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${path}"
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-alerting-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  RUNTIME_ROOT="${FIXTURE_ROOT}/runtime"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"

  mkdir -p "${FAKE_BIN}" "${RUNTIME_ROOT}" "${HOME}"

  export DWS_ALERT_LOG_PATH="${RUNTIME_ROOT}/alerts.log"
  export DWS_ALERT_MONITOR_LOG_PATH="${RUNTIME_ROOT}/monitor.log"
  export DWS_ALERT_BOOT_VERIFY_CMD="${FAKE_BIN}/dws-boot-verify.sh"
  export DWS_ALERT_TAILSCALE_REQUIRED_PEERS='mac=100.78.207.22 iphone=100.88.249.22 gateway=100.126.194.98'
  export DWS_ALERT_CRON_LOG_PATHS="${RUNTIME_ROOT}/health-check.log:${RUNTIME_ROOT}/log-rotate.log:${RUNTIME_ROOT}/session-cleanup.log"
  export DWS_ALERT_NOW_EPOCH
  DWS_ALERT_NOW_EPOCH=$(date -u -d '2026-04-23 10:10:00' '+%s')
  export DWS_ALERT_MONITOR_RESTART_WINDOW_SECONDS=600
  export DWS_ALERT_MONITOR_RESTART_LIMIT=3
  export DWS_ALERT_RATE_LIMIT_WINDOW_SECONDS=900
  export DWS_ALERT_RATE_LIMIT_LIMIT=2
  export DWS_ALERT_DISK_WARN_PCT=80
  export DWS_ALERT_CRON_FAILURE_WINDOW_SECONDS=86400
  export DWS_ALERT_CRON_TAIL_LINES=40

  write_fake_command dws-boot-verify.sh '
printf "overall: PASS (6 passed, 0 failed)\n"
'

  write_fake_command tailscale '
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--peers" ]; then
  cat <<'\''EOF'\''
100.117.16.63   dev-workspace-vm      Wrk-Flo@  linux  -
100.78.207.22   mosess-macbook-air-3  Wrk-Flo@  macOS  active; direct 72.24.145.11:50296
100.88.249.22   iphone-15-pro-max     Wrk-Flo@  iOS    active; relay "den"
100.126.194.98  openclaw-gateway-vm   Wrk-Flo@  linux  active; direct 20.124.180.8:41641
EOF
  exit 0
fi
exit 1
'

  write_fake_command df '
case "${1:-}" in
  -P)
    cat <<'\''EOF'\''
Filesystem     1024-blocks   Used Available Capacity Mounted on
/dev/root         1000000 400000    600000       40% /
EOF
    ;;
  -hP)
    cat <<'\''EOF'\''
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       100G   40G   60G  40% /
EOF
    ;;
  *)
    exit 1
    ;;
esac
'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset \
    DWS_ALERT_LOG_PATH \
    DWS_ALERT_MONITOR_LOG_PATH \
    DWS_ALERT_BOOT_VERIFY_CMD \
    DWS_ALERT_TAILSCALE_REQUIRED_PEERS \
    DWS_ALERT_CRON_LOG_PATHS \
    DWS_ALERT_NOW_EPOCH \
    DWS_ALERT_MONITOR_RESTART_WINDOW_SECONDS \
    DWS_ALERT_MONITOR_RESTART_LIMIT \
    DWS_ALERT_RATE_LIMIT_WINDOW_SECONDS \
    DWS_ALERT_RATE_LIMIT_LIMIT \
    DWS_ALERT_DISK_WARN_PCT \
    DWS_ALERT_CRON_FAILURE_WINDOW_SECONDS \
    DWS_ALERT_CRON_TAIL_LINES

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

seed_healthy_inputs() {
  cat >"${DWS_ALERT_MONITOR_LOG_PATH}" <<'EOF'
2026-04-23 10:01:00 monitor started
2026-04-23 10:06:00 monitor heartbeat
EOF

  cat >"${RUNTIME_ROOT}/health-check.log" <<'EOF'
PASS health check ok
EOF
  touch -d '2026-04-23 10:06:00' "${RUNTIME_ROOT}/health-check.log"
}

seed_failing_inputs() {
  cat >"${DWS_ALERT_MONITOR_LOG_PATH}" <<'EOF'
2026-04-23 10:01:00 monitor started
2026-04-23 10:03:00 monitor online
2026-04-23 10:05:00 monitor started
2026-04-23 10:07:00 monitor started
2026-04-23 10:04:00 ERROR rate limit from upstream (429)
2026-04-23 10:06:00 WARN retry-after 30s due to rate limit
2026-04-23 10:08:00 ERROR too many requests for worker dispatch
EOF

  cat >"${RUNTIME_ROOT}/health-check.log" <<'EOF'
PASS starting health-check
FAIL health-check command exited non-zero
EOF
  touch -d '2026-04-23 10:05:00' "${RUNTIME_ROOT}/health-check.log"

  write_fake_command dws-boot-verify.sh '
printf "  FAIL task-monitor service not active (dws-task-monitor.service)\n" >&2
printf "overall: FAIL (5 passed, 1 failed)\n" >&2
exit 1
'

  write_fake_command tailscale '
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--peers" ]; then
  cat <<'\''EOF'\''
100.117.16.63   dev-workspace-vm      Wrk-Flo@  linux  -
100.78.207.22   mosess-macbook-air-3  Wrk-Flo@  macOS  active; direct 72.24.145.11:50296
100.126.194.98  openclaw-gateway-vm   Wrk-Flo@  linux  active; direct 20.124.180.8:41641
EOF
  exit 0
fi
exit 1
'

  write_fake_command df '
case "${1:-}" in
  -P)
    cat <<'\''EOF'\''
Filesystem     1024-blocks   Used Available Capacity Mounted on
/dev/root         1000000 810000    190000       81% /
EOF
    ;;
  -hP)
    cat <<'\''EOF'\''
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       100G   81G   19G  81% /
EOF
    ;;
  *)
    exit 1
    ;;
esac
'
}

test_alerting_is_quiet_when_inputs_are_healthy() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  seed_healthy_inputs
  output=$(bash "${SCRIPT}" 2>&1)

  [ -z "${output}" ] || fail "expected no stdout for healthy run"
  if [ -f "${DWS_ALERT_LOG_PATH}" ] && [ -s "${DWS_ALERT_LOG_PATH}" ]; then
    fail "expected alert log to be empty for healthy run"
  fi

  cleanup_fixture
  trap - EXIT
}

test_alerting_logs_alerts_without_stdout_by_default() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  seed_failing_inputs
  if output=$(bash "${SCRIPT}" 2>&1); then
    fail "expected alerting run to exit non-zero"
  fi

  [ -z "${output}" ] || fail "expected alerts to stay off stdout without --stdout"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT monitor restart loop"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT monitor rate limits repeating"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT boot verify failed (FAIL task-monitor service not active (dws-task-monitor.service))"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT tailscale peers missing: iphone(100.88.249.22)"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT disk usage 81% on / (81G/100G used, 19G free)"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT cron job failure in health-check.log: FAIL health-check command exited non-zero"

  cleanup_fixture
  trap - EXIT
}

test_alerting_can_mirror_alerts_to_stdout() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  seed_failing_inputs
  if output=$(bash "${SCRIPT}" --stdout 2>&1); then
    fail "expected alerting run to exit non-zero"
  fi

  assert_contains "${output}" "ALERT monitor restart loop"
  assert_contains "${output}" "ALERT monitor rate limits repeating"
  assert_contains "${output}" "ALERT boot verify failed (FAIL task-monitor service not active (dws-task-monitor.service))"
  assert_contains "${output}" "ALERT tailscale peers missing: iphone(100.88.249.22)"
  assert_contains "${output}" "ALERT disk usage 81% on / (81G/100G used, 19G free)"
  assert_contains "${output}" "ALERT cron job failure in health-check.log: FAIL health-check command exited non-zero"
  assert_file_contains "${DWS_ALERT_LOG_PATH}" "ALERT monitor restart loop"

  cleanup_fixture
  trap - EXIT
}

test_alerting_is_quiet_when_inputs_are_healthy
test_alerting_logs_alerts_without_stdout_by_default
test_alerting_can_mirror_alerts_to_stdout

printf 'PASS: %s\n' "$(basename "$0")"
