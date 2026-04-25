#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/scripts/dws-update.sh"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-update.XXXXXX")
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
FAKE_BIN=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing output: $needle"
}

assert_not_contains() {
  local haystack="${1:-}" needle="${2:-}"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    fail "unexpected output: $needle"
  fi
}

write_fake_command() {
  local name="${1:-}" body="${2:-}" path
  path="${FAKE_BIN}/${name}"

  cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${path}"
}

cleanup() {
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  rm -rf -- "${FIXTURE_ROOT}"
}

trap cleanup EXIT

[ -x "${SCRIPT}" ] || fail "missing updater script: ${SCRIPT}"

export HOME="${FIXTURE_ROOT}/home"
FAKE_BIN="${FIXTURE_ROOT}/bin"
export PATH="${FAKE_BIN}:${ORIG_PATH}"

mkdir -p "${FAKE_BIN}" "${HOME}/bin"

write_fake_command git '
if [ "${1:-}" = "-C" ]; then
  shift 2
fi

if [ "${1:-}" = "status" ] && [ "${2:-}" = "--porcelain" ]; then
  printf " M scripts/dws-update.sh\n"
  exit 0
fi

if [ "${1:-}" = "pull" ]; then
  printf "unexpected git pull\n" >&2
  exit 99
fi

exit 1
'

install -m 0644 "${ROOT}/config/tmux.conf" "${HOME}/.tmux.conf"
printf '# stale boot verify copy\n' > "${HOME}/bin/dws-boot-verify.sh"
chmod 0755 "${HOME}/bin/dws-boot-verify.sh"
install -m 0755 "${ROOT}/scripts/dws-health.sh" "${HOME}/bin/dws-health.sh"
install -m 0755 "${ROOT}/scripts/dws-health-check.sh" "${HOME}/bin/dws-health-check.sh"
install -m 0755 "${ROOT}/scripts/dws-rotate-logs.sh" "${HOME}/bin/dws-rotate-logs.sh"
install -m 0755 "${ROOT}/scripts/dws-notify.sh" "${HOME}/bin/dws-notify.sh"
printf '# stale bootstrap copy\n' > "${HOME}/bin/dws-sessions-init.sh"
chmod 0755 "${HOME}/bin/dws-sessions-init.sh"

dry_run_output=$("${SCRIPT}" --dry-run 2>&1)
assert_contains "${dry_run_output}" "Skipping git pull: repo has local changes; using current checkout."
assert_contains "${dry_run_output}" "Would update:"
assert_contains "${dry_run_output}" "  - ~/bin/dws-boot-verify.sh"
assert_contains "${dry_run_output}" "  - ~/bin/dws-sessions-init.sh"
assert_not_contains "${dry_run_output}" "unexpected git pull"
assert_not_contains "${dry_run_output}" "  - ~/.tmux.conf"

apply_output=$("${SCRIPT}" --force 2>&1)
assert_contains "${apply_output}" "Changed:"
assert_contains "${apply_output}" "  - ~/bin/dws-boot-verify.sh"
assert_contains "${apply_output}" "  - ~/bin/dws-sessions-init.sh"
assert_not_contains "${apply_output}" "tmux reloaded"
assert_not_contains "${apply_output}" "unexpected git pull"

cmp -s "${ROOT}/bin/dws-boot-verify.sh" "${HOME}/bin/dws-boot-verify.sh" || \
  fail "live boot verify copy did not match repo script"

cmp -s "${ROOT}/scripts/dws-sessions-init.sh" "${HOME}/bin/dws-sessions-init.sh" || \
  fail "live bootstrap copy did not match repo script"

printf 'PASS: %s\n' "$(basename "$0")"
