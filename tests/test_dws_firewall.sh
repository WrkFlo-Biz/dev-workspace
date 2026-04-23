#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-firewall.sh"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-firewall-test.XXXXXX")
FAKE_BIN="${FIXTURE_ROOT}/bin"

cleanup() {
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

write_fake_command() {
  local name="$1"
  local path="${FAKE_BIN}/${name}"

  cat >"$path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$path"
}

reset_fake_bin() {
  rm -rf -- "${FAKE_BIN}"
  mkdir -p "${FAKE_BIN}"
}

test_script_is_executable() {
  [ -x "${SCRIPT}" ] || fail "expected executable script: ${SCRIPT}"
}

test_ufw_dry_run_logs_expected_rules() {
  local output

  reset_fake_bin
  write_fake_command ufw

  output=$(PATH="${FAKE_BIN}" "${BASH}" "${SCRIPT}" --dry-run --backend ufw 2>&1)

  assert_contains "${output}" 'using firewall backend: ufw'
  assert_contains "${output}" 'tailscale note: udp/41641 stays open globally so direct peers can reach this host'
  assert_contains "${output}" 'DRY-RUN: ufw --force reset'
  assert_contains "${output}" 'DRY-RUN: ufw default deny incoming'
  assert_contains "${output}" 'DRY-RUN: ufw default allow outgoing'
  assert_contains "${output}" 'DRY-RUN: ufw allow 41641/udp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 22 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 8080 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 9222 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 3000 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw --force enable'
  assert_contains "${output}" 'firewall configuration complete'
}

test_iptables_dry_run_logs_expected_rules() {
  local output

  reset_fake_bin
  write_fake_command iptables

  output=$(PATH="${FAKE_BIN}" "${BASH}" "${SCRIPT}" --dry-run --backend iptables 2>&1)

  assert_contains "${output}" 'using firewall backend: iptables'
  assert_contains "${output}" 'DRY-RUN: iptables -w -N DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -F DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -I INPUT 1 -j DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -i lo -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -m conntrack --ctstate RELATED\,ESTABLISHED -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p udp --dport 41641 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 22 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 8080 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 9222 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 3000 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -j DROP'
  assert_contains "${output}" 'drop all other inbound IPv4 traffic'
  assert_contains "${output}" 'firewall configuration complete'
}

trap cleanup EXIT

test_script_is_executable
test_ufw_dry_run_logs_expected_rules
test_iptables_dry_run_logs_expected_rules
printf 'ok\n'
