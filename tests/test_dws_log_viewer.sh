#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/dws-log-viewer.sh"

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

assert_ordered() {
  local haystack="$1" first="$2" second="$3"
  case "$haystack" in
    *"$first"*"$second"*) ;;
    *) fail "expected output order: ${first} before ${second}" ;;
  esac
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-log-viewer-test.XXXXXX")
  export DWS_LOG_DIR="${FIXTURE_ROOT}/var/log/dws"
  mkdir -p "${DWS_LOG_DIR}"
}

cleanup_fixture() {
  unset DWS_LOG_DIR DWS_LOG_VIEWER_TAIL_LINES TEST_BIN

  if [ -n "${FOLLOW_PID:-}" ]; then
    kill "${FOLLOW_PID}" >/dev/null 2>&1 || true
    wait "${FOLLOW_PID}" >/dev/null 2>&1 || true
    FOLLOW_PID=""
  fi

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

make_test_path_without_tail() {
  local cmd cmd_path

  TEST_BIN="${FIXTURE_ROOT}/bin"
  mkdir -p "${TEST_BIN}"

  for cmd in awk basename cat cut date find gzip sort stat; do
    cmd_path=$(command -v "${cmd}") || fail "missing required test command: ${cmd}"
    ln -s "${cmd_path}" "${TEST_BIN}/${cmd}"
  done
}

write_gzip_log() {
  local path="$1" content="$2"
  printf '%s' "$content" | gzip -c >"${path}"
}

test_filters_since_and_reads_archives() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_gzip_log "${DWS_LOG_DIR}/monitor.log.20260422T095500Z.gz" \
"2026-04-22 09:55:00 ERROR archived failure
2026-04-22 09:56:00 monitor archived heartbeat
"

  cat >"${DWS_LOG_DIR}/monitor.log" <<'EOF'
2026-04-23 10:00:00 monitor online
2026-04-23 10:05:00 ERROR current failure
EOF

  cat >"${DWS_LOG_DIR}/planner.log" <<'EOF'
2026-04-23 10:06:00 planner heartbeat
2026-04-23 10:07:00 ALERT schedule drift
EOF

  output=$(bash "${SCRIPT}" --since '2026-04-22 09:54:00' --grep 'ERROR|ALERT')
  assert_contains "${output}" "[monitor.log.20260422T095500Z.gz] 2026-04-22 09:55:00 ERROR archived failure"
  assert_contains "${output}" "[monitor.log] 2026-04-23 10:05:00 ERROR current failure"
  assert_contains "${output}" "[planner.log] 2026-04-23 10:07:00 ALERT schedule drift"
  assert_not_contains "${output}" "monitor archived heartbeat"
  assert_not_contains "${output}" "planner heartbeat"

  cleanup_fixture
  trap - EXIT
}

test_follow_streams_matching_updates() {
  local output_path output

  make_fixture
  trap cleanup_fixture EXIT

  export DWS_LOG_VIEWER_TAIL_LINES=0
  output_path="${FIXTURE_ROOT}/follow.out"
  : >"${DWS_LOG_DIR}/planner.log"

  bash "${SCRIPT}" --follow --grep 'ALERT' >"${output_path}" 2>&1 &
  FOLLOW_PID=$!

  sleep 1
  printf '2026-04-23 10:10:00 planner heartbeat\n' >>"${DWS_LOG_DIR}/planner.log"
  printf '2026-04-23 10:11:00 ALERT planner stalled\n' >>"${DWS_LOG_DIR}/planner.log"
  sleep 1

  kill "${FOLLOW_PID}" >/dev/null 2>&1 || true
  wait "${FOLLOW_PID}" >/dev/null 2>&1 || true
  FOLLOW_PID=""

  output=$(cat "${output_path}")
  assert_contains "${output}" "[planner.log] 2026-04-23 10:11:00 ALERT planner stalled"
  assert_not_contains "${output}" "planner heartbeat"

  cleanup_fixture
  trap - EXIT
}

test_non_follow_mode_does_not_require_tail() {
  local output bash_bin

  make_fixture
  trap cleanup_fixture EXIT

  cat >"${DWS_LOG_DIR}/monitor.log" <<'EOF'
2026-04-23 10:00:00 monitor online
2026-04-23 10:05:00 ERROR current failure
EOF

  make_test_path_without_tail
  bash_bin=$(command -v bash) || fail "bash not found"

  output=$(PATH="${TEST_BIN}" "${bash_bin}" "${SCRIPT}" --grep 'ERROR')
  assert_contains "${output}" "[monitor.log] 2026-04-23 10:05:00 ERROR current failure"

  cleanup_fixture
  trap - EXIT
}

test_non_follow_mode_merges_logs_by_timestamp() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  cat >"${DWS_LOG_DIR}/planner.log" <<'EOF'
2026-04-23 10:10:00 planner started
EOF

  cat >"${DWS_LOG_DIR}/monitor.log" <<'EOF'
2026-04-23 10:00:00 monitor started
EOF

  touch -d '2026-04-23 09:00:00' "${DWS_LOG_DIR}/planner.log"
  touch -d '2026-04-23 11:00:00' "${DWS_LOG_DIR}/monitor.log"

  output=$(bash "${SCRIPT}" --since '2026-04-23 09:50:00')
  assert_ordered \
    "${output}" \
    "[monitor.log] 2026-04-23 10:00:00 monitor started" \
    "[planner.log] 2026-04-23 10:10:00 planner started"

  cleanup_fixture
  trap - EXIT
}

test_filters_since_and_reads_archives
test_follow_streams_matching_updates
test_non_follow_mode_does_not_require_tail
test_non_follow_mode_merges_logs_by_timestamp

printf 'PASS: %s\n' "$(basename "$0")"
