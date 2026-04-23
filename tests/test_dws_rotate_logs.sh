#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/dws-rotate-logs.sh"

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

assert_exists() {
  [ -e "$1" ] || fail "expected path to exist: $1"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

assert_file_empty() {
  [ ! -s "$1" ] || fail "expected file to be empty: $1"
}

assert_gzip_contains() {
  local path="$1" needle="$2"
  gzip -dc -- "$path" | grep -F -- "$needle" >/dev/null 2>&1 || fail "expected ${path} to contain: ${needle}"
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-rotate-logs-test.XXXXXX")
  export DWS_LOG_DIR="${FIXTURE_ROOT}/var/log/dws"
  export DWS_LOG_RETENTION_WEEKS=4
  export DWS_LOG_ROTATE_TIMESTAMP=20260423T010203Z
  mkdir -p "${DWS_LOG_DIR}"
}

cleanup_fixture() {
  unset DWS_LOG_DIR DWS_LOG_RETENTION_WEEKS DWS_LOG_ROTATE_TIMESTAMP

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

write_archive() {
  local path="$1" content="$2"
  printf '%s' "$content" | gzip -c >"${path}"
}

test_rotates_and_prunes_to_four_archives() {
  local output archive_path

  make_fixture
  trap cleanup_fixture EXIT

  cat >"${DWS_LOG_DIR}/monitor.log" <<'EOF'
2026-04-23 10:00:00 monitor online
2026-04-23 10:05:00 monitor heartbeat
EOF
  : >"${DWS_LOG_DIR}/worker.log"

  write_archive "${DWS_LOG_DIR}/monitor.log.20260416T010203Z.gz" 'older-a
'
  write_archive "${DWS_LOG_DIR}/monitor.log.20260409T010203Z.gz" 'older-b
'
  write_archive "${DWS_LOG_DIR}/monitor.log.20260402T010203Z.gz" 'older-c
'
  write_archive "${DWS_LOG_DIR}/monitor.log.20260326T010203Z.gz" 'older-d
'

  output=$(bash "${SCRIPT}")
  archive_path="${DWS_LOG_DIR}/monitor.log.20260423T010203Z.gz"

  assert_contains "${output}" "rotated ${DWS_LOG_DIR}/monitor.log -> ${archive_path}"
  assert_contains "${output}" "skip empty ${DWS_LOG_DIR}/worker.log"
  assert_contains "${output}" "pruned ${DWS_LOG_DIR}/monitor.log.20260326T010203Z.gz"
  assert_contains "${output}" "rotated: 1"
  assert_contains "${output}" "skipped: 1"
  assert_contains "${output}" "pruned:  1"

  assert_exists "${archive_path}"
  assert_gzip_contains "${archive_path}" '2026-04-23 10:05:00 monitor heartbeat'
  assert_file_empty "${DWS_LOG_DIR}/monitor.log"
  assert_not_exists "${DWS_LOG_DIR}/monitor.log.20260326T010203Z.gz"

  cleanup_fixture
  trap - EXIT
}

test_rotates_and_prunes_to_four_archives

printf 'PASS: %s\n' "$(basename "$0")"
