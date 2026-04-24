#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-cron-setup.sh"

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
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-cron-setup-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export DWS_TEST_CRONTAB_PATH="${FIXTURE_ROOT}/crontab.txt"
  export DWS_HEALTH_CHECK_SCRIPT="${REPO_ROOT}/scripts/dws-health-check.sh"
  export DWS_CLEANUP_SCRIPT="${REPO_ROOT}/scripts/dws-cleanup.sh"
  export DWS_LOG_ROTATE_SCRIPT="${FIXTURE_ROOT}/dws-rotate-logs.sh"
  export DWS_LOG_RETENTION_WEEKS=4

  mkdir -p "${FAKE_BIN}" "${HOME}"
  : >"${DWS_TEST_CRONTAB_PATH}"

  cat >"${DWS_LOG_ROTATE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${DWS_LOG_ROTATE_SCRIPT}"

  write_fake_command crontab '
if [ "${1:-}" = "-l" ]; then
  [ -f "${DWS_TEST_CRONTAB_PATH}" ] && cat "${DWS_TEST_CRONTAB_PATH}"
  exit 0
fi
if [ $# -eq 1 ]; then
  cat "$1" >"${DWS_TEST_CRONTAB_PATH}"
  exit 0
fi
exit 0
'

  write_fake_command systemctl '
if [ "${1:-}" = "is-active" ]; then
  exit 0
fi
exit 1
'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset DWS_TEST_CRONTAB_PATH DWS_CRON_LOG_DIR DWS_HEALTH_CHECK_SCRIPT DWS_LOG_ROTATE_SCRIPT DWS_CLEANUP_SCRIPT DWS_LOG_RETENTION_WEEKS

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

test_show_defaults_to_var_log_dws() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  unset DWS_CRON_LOG_DIR
  output=$(bash "${SCRIPT}" --show 2>&1)
  assert_contains "${output}" "# >>> dev-workspace managed cron >>>"
  assert_contains "${output}" "*/15 * * * * \"${REPO_ROOT}/scripts/dws-health-check.sh\" >>\"/var/log/dws/health-check.log\" 2>&1 # dws-health-check"
  assert_contains "${output}" "30 2 * * 0 \"${DWS_LOG_ROTATE_SCRIPT}\" --keep-weeks 4 >>\"/var/log/dws/log-rotate.log\" 2>&1 # dws-log-rotate"
  assert_not_contains "${output}" "/tmp/dws-health-check.cron.log"
  assert_not_contains "${output}" "dws-health-check.cron.log"
  assert_contains "${output}" "Summary: 0 pass, 0 fail"

  cleanup_fixture
  trap - EXIT
}

test_show_uses_repo_rotate_helper_when_env_is_unset() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  unset DWS_CRON_LOG_DIR DWS_LOG_ROTATE_SCRIPT
  output=$(bash "${SCRIPT}" --show 2>&1)
  assert_contains "${output}" "30 2 * * 0 \"${REPO_ROOT}/scripts/dws-rotate-logs.sh\" --keep-weeks 4 >>\"/var/log/dws/log-rotate.log\" 2>&1 # dws-log-rotate"

  cleanup_fixture
  trap - EXIT
}

test_install_replaces_legacy_tmp_health_check_block() {
  local output crontab_after

  make_fixture
  trap cleanup_fixture EXIT

  export DWS_CRON_LOG_DIR="${FIXTURE_ROOT}/var/log/dws"
  cat >"${DWS_TEST_CRONTAB_PATH}" <<'EOF'
MAILTO=ops@example.com
# >>> dev-workspace health check >>>
*/15 * * * * "/home/moses/bin/dws-health-check.sh" >>"/tmp/dws-health-check.cron.log" 2>&1
# <<< dev-workspace health check <<<
5 * * * * echo keep-me
EOF

  output=$(bash "${SCRIPT}" 2>&1)
  crontab_after=$(cat "${DWS_TEST_CRONTAB_PATH}")

  assert_contains "${output}" "PASS installed managed dev-workspace cron block"
  assert_contains "${output}" "PASS cron service is active"
  assert_contains "${crontab_after}" "5 * * * * echo keep-me"
  assert_contains "${crontab_after}" "# >>> dev-workspace managed cron >>>"
  assert_contains "${crontab_after}" "*/15 * * * * \"${REPO_ROOT}/scripts/dws-health-check.sh\" >>\"${DWS_CRON_LOG_DIR}/health-check.log\" 2>&1 # dws-health-check"
  assert_contains "${crontab_after}" "30 2 * * 0 \"${DWS_LOG_ROTATE_SCRIPT}\" --keep-weeks 4 >>\"${DWS_CRON_LOG_DIR}/log-rotate.log\" 2>&1 # dws-log-rotate"
  assert_not_contains "${crontab_after}" "/tmp/dws-health-check.cron.log"
  assert_not_contains "${crontab_after}" "dws-log-rotate.cron.log"
  assert_not_contains "${crontab_after}" "# >>> dev-workspace health check >>>"

  cleanup_fixture
  trap - EXIT
}

test_dry_run_does_not_modify_crontab() {
  local output crontab_after

  make_fixture
  trap cleanup_fixture EXIT

  export DWS_CRON_LOG_DIR="${FIXTURE_ROOT}/var/log/dws"
  cat >"${DWS_TEST_CRONTAB_PATH}" <<'EOF'
MAILTO=ops@example.com
5 * * * * echo keep-me
EOF

  output=$(bash "${SCRIPT}" --dry-run 2>&1)
  crontab_after=$(cat "${DWS_TEST_CRONTAB_PATH}")

  assert_contains "${output}" "PASS dry-run: would create cron log dir: ${DWS_CRON_LOG_DIR}"
  assert_contains "${output}" "PASS dry-run: would install managed dev-workspace cron block"
  assert_contains "${output}" "PASS dry-run: skipped installed-state verification"
  assert_contains "${output}" "5 * * * * echo keep-me"
  assert_contains "${output}" "# >>> dev-workspace managed cron >>>"
  assert_contains "${output}" "30 2 * * 0 \"${DWS_LOG_ROTATE_SCRIPT}\" --keep-weeks 4 >>\"${DWS_CRON_LOG_DIR}/log-rotate.log\" 2>&1 # dws-log-rotate"
  assert_contains "${crontab_after}" "5 * * * * echo keep-me"
  assert_not_contains "${crontab_after}" "# >>> dev-workspace managed cron >>>"

  cleanup_fixture
  trap - EXIT
}

test_show_defaults_to_var_log_dws
test_show_uses_repo_rotate_helper_when_env_is_unset
test_install_replaces_legacy_tmp_health_check_block
test_dry_run_does_not_modify_crontab

printf 'PASS: %s\n' "$(basename "$0")"
