#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT_SEC="${DWS_TEST_TIMEOUT_SEC:-60}"

discover_tests() {
  find "${BASE_DIR}" -maxdepth 1 -type f -name 'test_*.sh' | sort
}

main() {
  local -a tests=()
  local -a failed_tests=()
  local failures=0
  local test_file

  mapfile -t tests < <(discover_tests)

  if [ "${#tests[@]}" -eq 0 ]; then
    printf 'No shell tests found under %s\n' "${BASE_DIR}" >&2
    return 1
  fi

  printf 'Discovered %s shell test files\n' "${#tests[@]}"

  for test_file in "${tests[@]}"; do
    printf '\n==> %s\n' "${test_file}"
    if timeout "${TIMEOUT_SEC}" bash "${test_file}"; then
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
