#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-termius-setup.sh"
ORIG_HOME="${HOME}"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-termius-test.XXXXXX")

cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf -- "${FIXTURE_ROOT}"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing output: $needle"
}

trap cleanup EXIT

[ -x "$SCRIPT" ] || fail "missing helper: $SCRIPT"

export HOME="${FIXTURE_ROOT}/home"
mkdir -p "${HOME}/.ssh"

printf 'fake-private-key\n' >"${HOME}/.ssh/termius_20260415"
chmod 600 "${HOME}/.ssh/termius_20260415"

output=$(bash "$SCRIPT")
assert_contains "$output" "Hostname: 100.117.16.63"
assert_contains "$output" "Port: 22"
assert_contains "$output" "Username: moses"
assert_contains "$output" "SSH key path: ${HOME}/.ssh/termius_20260415 (present)"
assert_contains "$output" "Terminal type: xterm-256color"
assert_contains "$output" "tmux prefix: Ctrl-a"

custom_key="${FIXTURE_ROOT}/custom/phone-key"
mkdir -p "$(dirname "$custom_key")"
printf 'override-key\n' >"$custom_key"
chmod 600 "$custom_key"

override_output=$(DWS_TERMIUS_KEY_PATH="$custom_key" bash "$SCRIPT")
assert_contains "$override_output" "SSH key path: ${custom_key} (present)"

rm -f "$custom_key"
missing_output=$(DWS_TERMIUS_KEY_PATH="$custom_key" bash "$SCRIPT")
assert_contains "$missing_output" "SSH key path: ${custom_key} (missing)"

printf 'PASS: dws termius helper\n'
