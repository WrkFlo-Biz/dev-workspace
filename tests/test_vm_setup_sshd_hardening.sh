#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/vm-setup.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"

  if ! grep -Fq -- "$needle" "$SCRIPT"; then
    fail "expected ${SCRIPT} to contain: $needle"
  fi
}

assert_contains 'local hardening_file="/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf"'
assert_contains 'ChallengeResponseAuthentication no'
assert_contains 'X11Forwarding no'
assert_contains 'MaxAuthTries 3'
assert_contains 'ClientAliveInterval 30'
assert_contains 'ClientAliveCountMax 3'

printf 'PASS: %s\n' "$(basename "$0")"
