#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT_SEC="${DWS_TEST_TIMEOUT_SEC:-60}"
BACKUP_TIMEOUT_SEC="${DWS_TEST_TIMEOUT_BACKUP_SEC:-240}"

discover_tests() {
  find "${BASE_DIR}" -maxdepth 1 -type f -name 'test_*.sh' | sort
}

timeout_for_test() {
  case "${1:-}" in
    */test_dws_backup.sh|test_dws_backup.sh) printf '%s\n' "${BACKUP_TIMEOUT_SEC}" ;;
    *) printf '%s\n' "${TIMEOUT_SEC}" ;;
  esac
}

main() {
  local -a tests=()
  local -a failed_tests=()
  local failures=0
  local test_file timeout_sec

  mapfile -t tests < <(discover_tests)

  if [ "${#tests[@]}" -eq 0 ]; then
    printf 'No shell tests found under %s\n' "${BASE_DIR}" >&2
    return 1
  fi

  printf 'Discovered %s shell test files\n' "${#tests[@]}"

  for test_file in "${tests[@]}"; do
    timeout_sec=$(timeout_for_test "${test_file}")
    printf '\n==> %s (timeout %ss)\n' "${test_file}" "${timeout_sec}"
    if timeout "${timeout_sec}" bash "${test_file}"; then
      printf 'PASS %s\n' "${test_file}"
    else
      local status=$?
      printf 'FAIL %s (exit %s)\n' "${test_file}" "${status}" >&2
      failed_tests+=("${test_file} (exit ${status})")
      failures=$((failures + 1))
    fi
  done

  if [ "${failures}" -ne 0 ]; then
    printf '\nFailed test files (%s):\n' "${failures}" >&2
    printf ' - %s\n' "${failed_tests[@]}" >&2
    return 1
  fi

  printf '\nAll %s shell test files passed\n' "${#tests[@]}"
}

main "$@"
