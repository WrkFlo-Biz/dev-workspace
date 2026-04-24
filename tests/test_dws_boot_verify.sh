#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-boot-verify.sh"

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

  cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${path}"
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-boot-verify-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export NO_COLOR=1
  export DWS_BOOT_VERIFY_LOG_DIR="${FIXTURE_ROOT}/var/log/dws"

  mkdir -p "${FAKE_BIN}" "${HOME}" "${DWS_BOOT_VERIFY_LOG_DIR}"

  write_fake_command hostname '
if [ "${1:-}" = "-s" ]; then
  printf "dev-workspace-vm\n"
  exit 0
fi
printf "dev-workspace-vm.example.net\n"
'

  write_fake_command date '
printf "2026-04-23 12:00:00 UTC\n"
'

  write_fake_command tailscale '
case "${1:-} ${2:-}" in
  "status ")
    exit "${FAKE_TAILSCALE_STATUS_EXIT:-0}"
    ;;
  "ip -4")
    printf "%s\n" "${FAKE_TAILSCALE_IP:-100.117.16.63}"
    exit 0
    ;;
esac
exit 1
'

  write_fake_command python3 '
if [ "${FAKE_SSH_BANNER_MODE:-ok}" = "fail" ]; then
  exit 1
fi
printf "%s\n" "${FAKE_SSH_BANNER:-SSH-2.0-OpenSSH_9.7}"
'

  write_fake_command systemctl '
scope="system"
if [ "${1:-}" = "--user" ]; then
  scope="user"
  shift
fi

if [ "${1:-}" = "is-active" ]; then
  shift
  if [ "${1:-}" = "--quiet" ]; then
    shift
  fi
  unit="${1:-}"
  case "${scope}:${unit}" in
    system:tailscaled.service|system:tailscaled|system:ssh.socket|system:ssh.service|system:cron.service|system:cron)
      exit 0
      ;;
    user:dws-task-monitor.service|user:dws-task-monitor)
      if [ "${FAKE_TASK_MONITOR_ACTIVE:-1}" = "1" ]; then
        exit 0
      fi
      exit 3
      ;;
  esac
  exit 3
fi

exit 1
'

  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  cat <<'\''EOF'\''
dws-a
dws-b
worker-c
worker-d
worker-e
worker-f
worker-g
worker-h
worker-i
orchestrator
EOF
  exit 0
fi
exit 1
'

  write_fake_command crontab '
if [ "${1:-}" = "-l" ]; then
  printf "%s\n" "*/15 * * * * /home/moses/bin/dws-health-check.sh"
  printf "%s\n" "30 2 * * * /home/moses/bin/dws-cleanup.sh"
  exit 0
fi
exit 1
'

  printf 'boot verifier log\n' >"${DWS_BOOT_VERIFY_LOG_DIR}/boot.log"
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset NO_COLOR \
    DWS_BOOT_VERIFY_LOG_DIR \
    FAKE_TAILSCALE_STATUS_EXIT \
    FAKE_TAILSCALE_IP \
    FAKE_SSH_BANNER_MODE \
    FAKE_SSH_BANNER \
    FAKE_TASK_MONITOR_ACTIVE

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

test_boot_verify_passes_when_all_checks_are_ready() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  [ -x "${SCRIPT}" ] || fail "script is not executable"

  output=$("${SCRIPT}" 2>&1)
  assert_contains "${output}" "DWS Boot Verify"
  assert_contains "${output}" "PASS tailscale up (100.117.16.63; tailscaled.service)"
  assert_contains "${output}" "PASS ssh accepting connections on 127.0.0.1:22 (SSH-2.0-OpenSSH_9.7; active ssh.socket, ssh.service)"
  assert_contains "${output}" "PASS tmux managed sessions ready (10 sessions: dws-a, dws-b, worker-c, worker-d, worker-e, worker-f, worker-g, worker-h, worker-i, orchestrator)"
  assert_contains "${output}" "PASS cron loaded (cron.service; 2 active crontab entries)"
  assert_contains "${output}" "PASS log directory present (${DWS_BOOT_VERIFY_LOG_DIR}; 1 entries)"
  assert_contains "${output}" "PASS task-monitor service active (user dws-task-monitor.service)"
  assert_contains "${output}" "overall: PASS (6 passed, 0 failed)"
  assert_not_contains "${output}" "FAIL "

  cleanup_fixture
  trap - EXIT
}

test_boot_verify_fails_when_task_monitor_is_inactive() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  export FAKE_TASK_MONITOR_ACTIVE=0

  if output=$("${SCRIPT}" 2>&1); then
    fail "expected dws-boot-verify.sh to fail"
  fi

  assert_contains "${output}" "FAIL task-monitor service not active (dws-task-monitor.service)"
  assert_contains "${output}" "overall: FAIL (5 passed, 1 failed)"

  cleanup_fixture
  trap - EXIT
}

test_boot_verify_fails_when_worker_i_is_missing() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  cat <<'\''EOF'\''
dws-a
dws-b
worker-c
worker-d
worker-e
worker-f
worker-g
worker-h
orchestrator
EOF
  exit 0
fi
exit 1
'

  if output=$("${SCRIPT}" 2>&1); then
    fail "expected dws-boot-verify.sh to fail when worker-i is missing"
  fi

  assert_contains "${output}" "FAIL tmux managed sessions missing (worker-i; active: dws-a, dws-b, worker-c, worker-d, worker-e, worker-f, worker-g, worker-h, orchestrator)"
  assert_contains "${output}" "overall: FAIL (5 passed, 1 failed)"

  cleanup_fixture
  trap - EXIT
}

test_boot_verify_fails_when_worker_i_is_missing() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  cat <<'\''EOF'\''
dws-a
dws-b
worker-c
worker-d
worker-e
worker-f
worker-g
worker-h
orchestrator
EOF
  exit 0
fi
exit 1
'

  if output=$("${SCRIPT}" 2>&1); then
    fail "expected dws-boot-verify.sh to fail when worker-i is missing"
  fi

  assert_contains "${output}" "FAIL tmux managed sessions missing (worker-i; active: dws-a, dws-b, worker-c, worker-d, worker-e, worker-f, worker-g, worker-h, orchestrator)"
  assert_contains "${output}" "overall: FAIL (5 passed, 1 failed)"

  cleanup_fixture
  trap - EXIT
}

test_boot_verify_passes_when_all_checks_are_ready
test_boot_verify_fails_when_task_monitor_is_inactive
test_boot_verify_fails_when_worker_i_is_missing

printf 'PASS: %s\n' "$(basename "$0")"
