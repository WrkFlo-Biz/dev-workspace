#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

is_standalone_bin_program() {
  case "${1:-}" in
    dws-boot-verify.sh|dws-systemd-user-setup.sh) return 0 ;;
    *) return 1 ;;
  esac
}

test_bin_wrappers_exec_matching_scripts() {
  local wrapper name expected exec_lines

  while IFS= read -r wrapper; do
    name=$(basename "$wrapper")

    if is_standalone_bin_program "$name"; then
      continue
    fi

    expected="${REPO_ROOT}/scripts/${name}"
    [ -x "$wrapper" ] || fail "wrapper is not executable: ${wrapper}"
    [ -x "$expected" ] || fail "missing executable counterpart for ${wrapper}: ${expected}"

    exec_lines=$(awk '/^exec / { print }' "$wrapper")
    [ -n "$exec_lines" ] || fail "wrapper does not exec a target: ${wrapper}"

    printf '%s\n' "$exec_lines" | grep -F "../scripts/${name}" >/dev/null 2>&1 || \
      fail "wrapper does not exec scripts/${name}: ${wrapper}"
  done < <(find "${REPO_ROOT}/bin" -maxdepth 1 -type f -name '*.sh' | sort)
}

test_bin_wrappers_exec_matching_scripts

printf 'PASS: %s\n' "$(basename "$0")"
