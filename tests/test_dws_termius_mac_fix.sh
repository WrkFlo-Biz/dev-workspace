#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-termius-mac-fix.sh"
ORIG_HOME="${HOME}"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-termius-mac-fix-test.XXXXXX")

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

assert_mode() {
  local path="${1:-}" expected="${2:-}" actual

  actual=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || true)
  [ "$actual" = "$expected" ] || fail "unexpected mode for $path: got ${actual:-unknown}, want $expected"
}

trap cleanup EXIT

[ -x "$SCRIPT" ] || fail "missing helper: $SCRIPT"

export HOME="${FIXTURE_ROOT}/home"
mkdir -p "${HOME}/.ssh" "${FIXTURE_ROOT}/etc/ssh" "${FIXTURE_ROOT}/bin"
chmod 777 "${HOME}"
chmod 755 "${HOME}/.ssh"
printf 'ssh-ed25519 AAAATEST termius\n' >"${HOME}/.ssh/authorized_keys"
chmod 644 "${HOME}/.ssh/authorized_keys"

cat >"${FIXTURE_ROOT}/etc/ssh/sshd_config" <<'EOF'
# macOS sshd baseline
Include /etc/ssh/sshd_config.d/*
PasswordAuthentication yes
PubkeyAuthentication no
EOF

SSHD_LOG="${FIXTURE_ROOT}/sshd.log"
cat >"${FIXTURE_ROOT}/bin/sshd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${SSHD_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_ROOT}/bin/sshd"

output=$(
  DWS_TERMIUS_MAC_FIX_SSHD_CONFIG="${FIXTURE_ROOT}/etc/ssh/sshd_config" \
  DWS_TERMIUS_MAC_FIX_HOME_DIR="${HOME}" \
  DWS_TERMIUS_MAC_FIX_SSH_DIR="${HOME}/.ssh" \
  DWS_TERMIUS_MAC_FIX_AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys" \
  DWS_TERMIUS_MAC_FIX_SSHD_BIN="${FIXTURE_ROOT}/bin/sshd" \
  bash "$SCRIPT"
)

assert_contains "$output" "updated sshd_config: ${FIXTURE_ROOT}/etc/ssh/sshd_config"
assert_contains "$output" "set permissions: ${HOME}/.ssh -> 700"
assert_contains "$output" "set permissions: ${HOME}/.ssh/authorized_keys -> 600"
assert_contains "$output" "verified sshd config: ${FIXTURE_ROOT}/bin/sshd -t -f ${FIXTURE_ROOT}/etc/ssh/sshd_config"

first_pubkey=$(awk 'tolower($0) ~ /^[[:space:]]*pubkeyauthentication[[:space:]]+/ { print; exit }' "${FIXTURE_ROOT}/etc/ssh/sshd_config")
[ "$first_pubkey" = "PubkeyAuthentication yes" ] || fail "first pubkey directive was not forced to yes"

assert_mode "${HOME}" "755"
assert_mode "${HOME}/.ssh" "700"
assert_mode "${HOME}/.ssh/authorized_keys" "600"

sshd_args=$(cat "${SSHD_LOG}")
[ "$sshd_args" = "-t -f ${FIXTURE_ROOT}/etc/ssh/sshd_config" ] || fail "unexpected sshd args: $sshd_args"

second_output=$(
  DWS_TERMIUS_MAC_FIX_SSHD_CONFIG="${FIXTURE_ROOT}/etc/ssh/sshd_config" \
  DWS_TERMIUS_MAC_FIX_HOME_DIR="${HOME}" \
  DWS_TERMIUS_MAC_FIX_SSH_DIR="${HOME}/.ssh" \
  DWS_TERMIUS_MAC_FIX_AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys" \
  DWS_TERMIUS_MAC_FIX_SSHD_BIN="${FIXTURE_ROOT}/bin/sshd" \
  bash "$SCRIPT"
)
assert_contains "$second_output" "sshd_config already ensures PubkeyAuthentication yes: ${FIXTURE_ROOT}/etc/ssh/sshd_config"

printf 'PASS: dws termius mac fix\n'
