#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_exact_line() {
  local file="$1" expected="$2"

  grep -Fqx -- "$expected" "$file" || fail "missing line in ${file}: ${expected}"
}

is_standalone_bin_program() {
  case "${1:-}" in
    dws-boot-verify.sh|dws-systemd-user-setup.sh) return 0 ;;
    *) return 1 ;;
  esac
}

expected_wrapper_comment_line() {
  case "${1:-}" in
    dws-sessions-init.sh)
      printf '# Wrapper — on-demand session bootstrap lives in scripts/%s\n' "$1"
      ;;
    *)
      printf '# Wrapper — canonical source is scripts/%s\n' "$1"
      ;;
  esac
}

test_bin_wrappers_exec_matching_scripts() {
  local wrapper_rel wrapper name expected exec_lines

  while IFS= read -r wrapper_rel; do
    [ -n "$wrapper_rel" ] || continue
    wrapper="${REPO_ROOT}/${wrapper_rel}"
    name=$(basename "$wrapper_rel")

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
  done < <(git -C "${REPO_ROOT}" ls-files 'bin/*.sh' | sort)
}

test_bin_wrappers_use_consistent_base_dir_contract() {
  local wrapper_rel wrapper name expected_comment_line expected_exec_line

  while IFS= read -r wrapper_rel; do
    [ -n "$wrapper_rel" ] || continue
    wrapper="${REPO_ROOT}/${wrapper_rel}"
    name=$(basename "$wrapper_rel")

    if is_standalone_bin_program "$name"; then
      continue
    fi

    assert_exact_line "$wrapper" 'set -euo pipefail'
    expected_comment_line=$(expected_wrapper_comment_line "$name")
    assert_exact_line "$wrapper" "$expected_comment_line"
    assert_exact_line "$wrapper" 'BASE_DIR="${BASH_SOURCE[0]%/*}"'
    assert_exact_line "$wrapper" '[ "$BASE_DIR" != "${BASH_SOURCE[0]}" ] || BASE_DIR='\''.'\'''
    assert_exact_line "$wrapper" 'BASE_DIR=$(CDPATH='\'''\'' cd -- "$BASE_DIR" && pwd)'

    expected_exec_line=$(printf 'exec "${BASE_DIR}/../scripts/%s" "$@"' "$name")
    assert_exact_line "$wrapper" "$expected_exec_line"
  done < <(git -C "${REPO_ROOT}" ls-files 'bin/*.sh' | sort)
}

test_bin_wrappers_exec_matching_scripts
test_bin_wrappers_use_consistent_base_dir_contract

printf 'PASS: %s\n' "$(basename "$0")"
