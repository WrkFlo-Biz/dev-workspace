#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/vm-setup.sh"

ORIG_PATH="${PATH}"
ORIG_HOME="${HOME}"
ORIG_USER="${USER:-$(id -un)}"

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
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vm-setup-cron-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  FIXTURE_SCRIPT_DIR="${FIXTURE_ROOT}/scripts"
  FIXTURE_SCRIPT="${FIXTURE_SCRIPT_DIR}/vm-setup.sh"
  export HOME="${FIXTURE_ROOT}/home"
  export USER="${ORIG_USER}"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export DWS_TEST_CRONTAB_PATH="${FIXTURE_ROOT}/crontab.txt"
  export DWS_CRON_LOG_DIR="${FIXTURE_ROOT}/var/log/dws"

  mkdir -p "${FAKE_BIN}" "${HOME}/bin" "${FIXTURE_SCRIPT_DIR}"
  : >"${DWS_TEST_CRONTAB_PATH}"

  cat >"${HOME}/bin/dws-health-check.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${HOME}/bin/dws-health-check.sh"

  write_fake_command crontab '
if [ "${1:-}" = "-l" ]; then
  [ -f "${DWS_TEST_CRONTAB_PATH}" ] && cat "${DWS_TEST_CRONTAB_PATH}"
  exit 0
fi
if [ $# -eq 1 ]; then
  cat "$1" >"${DWS_TEST_CRONTAB_PATH}"
  exit 0
fi
exit 1
'

  write_fake_command sudo 'exec "$@"'

  sed '/^main "\$@"/d' "${SCRIPT}" >"${FIXTURE_SCRIPT}"
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  export USER="${ORIG_USER}"
  unset DWS_TEST_CRONTAB_PATH DWS_CRON_LOG_DIR

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

load_vm_setup_functions() {
  # shellcheck disable=SC1090
  source "${FIXTURE_SCRIPT}"
}

test_ensure_health_check_cron_redirects_to_var_log_dws() {
  local crontab_after

  make_fixture
  trap cleanup_fixture EXIT

  cat >"${DWS_TEST_CRONTAB_PATH}" <<EOF
# >>> dev-workspace health check >>>
*/15 * * * * "${HOME}/bin/dws-health-check.sh" >>"/tmp/dws-health-check.cron.log" 2>&1
# <<< dev-workspace health check <<<
EOF

  load_vm_setup_functions
  ensure_health_check_cron
  crontab_after=$(cat "${DWS_TEST_CRONTAB_PATH}")

  [ -d "${DWS_CRON_LOG_DIR}" ] || fail "expected cron log directory to be created"
  [ -w "${DWS_CRON_LOG_DIR}" ] || fail "expected cron log directory to be writable"
  assert_contains "${crontab_after}" "# >>> dev-workspace health check >>>"
  assert_contains "${crontab_after}" "*/15 * * * * \"${HOME}/bin/dws-health-check.sh\" >>\"${DWS_CRON_LOG_DIR}/dws-health-check.cron.log\" 2>&1"
  assert_not_contains "${crontab_after}" "/tmp/dws-health-check.cron.log"
  assert_not_contains "${crontab_after}" ">/dev/null 2>&1"

  cleanup_fixture
  trap - EXIT
}

test_ensure_health_check_cron_redirects_to_var_log_dws

printf 'PASS: %s\n' "$(basename "$0")"
