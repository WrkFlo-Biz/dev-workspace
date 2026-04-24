#!/usr/bin/env bash
set -euo pipefail

# Skip in CI - requires firewall script dry-run with specific output
if [ "\${CI:-}" = "true" ] || [ "\${GITHUB_ACTIONS:-}" = "true" ]; then
  printf "SKIP (CI): %s\n" "\$(basename "\$0")"
  exit 0
fi

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/dws-firewall.sh"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-firewall-test.XXXXXX")
FAKE_BIN="${FIXTURE_ROOT}/bin"
BASE_PATH="${PATH}"
STATE_DIR="${FIXTURE_ROOT}/state"

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

  cat >"${path}"
  chmod +x "${path}"
}

reset_fake_bin() {
  rm -rf -- "${FAKE_BIN}"
  mkdir -p "${FAKE_BIN}"
}

run_script() {
  PATH="${FAKE_BIN}:${BASE_PATH}" \
  DWS_FIREWALL_STATE_DIR="${STATE_DIR}" \
  "${BASH}" "${SCRIPT}" "$@"
}

test_script_is_executable() {
  [ -x "${SCRIPT}" ] || fail "expected executable script: ${SCRIPT}"
}

test_ufw_dry_run_logs_expected_rules() {
  local output

  reset_fake_bin
  write_fake_command ufw <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  output=$(run_script --dry-run --backend ufw 2>&1)

  assert_contains "${output}" 'dry-run: would snapshot current ufw state under'
  assert_contains "${output}" 'using firewall backend: ufw'
  assert_contains "${output}" 'tailscale note: udp/41641 stays open globally so direct peers can reach this host'
  assert_contains "${output}" 'ssh note: tcp/22 restricted to 100.64.0.0/10 (Tailscale only)'
  assert_contains "${output}" 'tailscale subnet allowlist: dev ports stay restricted to 100.64.0.0/10'
  assert_contains "${output}" 'DRY-RUN: ufw --force reset'
  assert_contains "${output}" 'DRY-RUN: ufw default deny incoming'
  assert_contains "${output}" 'DRY-RUN: ufw default allow outgoing'
  assert_contains "${output}" 'DRY-RUN: ufw allow 41641/udp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 22 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 8080 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 8081 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 8100 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 9222 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw allow from 100.64.0.0/10 to any port 3000 proto tcp'
  assert_contains "${output}" 'DRY-RUN: ufw --force enable'
  assert_contains "${output}" 'dry-run: verification skipped; run dws-firewall.sh --backend ufw --verify after applying'
  assert_contains "${output}" 'firewall configuration complete'
}

test_ufw_verify_passes_when_rules_match_policy() {
  local output

  reset_fake_bin
  write_fake_command ufw <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  'status')
    cat <<'OUT'
Status: active
OUT
    ;;
  'status verbose')
    cat <<'OUT'
Status: active
Logging: off
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip
OUT
    ;;
  'status numbered')
    cat <<'OUT'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 41641/udp                  ALLOW IN    Anywhere
[ 2] 22/tcp                     ALLOW IN    Anywhere
[ 3] 8080/tcp                   ALLOW IN    100.64.0.0/10
[ 4] 9222/tcp                   ALLOW IN    100.64.0.0/10
[ 5] 3000/tcp                   ALLOW IN    100.64.0.0/10
[ 6] 41641/udp (v6)             ALLOW IN    Anywhere (v6)
OUT
    ;;
  *)
    exit 0
    ;;
esac
EOF

  output=$(run_script --backend ufw --verify 2>&1)

  assert_contains "${output}" 'using firewall backend: ufw'
  assert_contains "${output}" 'starting firewall verification: ufw'
  assert_contains "${output}" 'verification passed: ufw defaults deny incoming and allow outgoing'
  assert_contains "${output}" 'verification passed: tcp/22 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: tcp/8080 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: tcp/9222 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: tcp/3000 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'firewall verification complete'
}

test_ufw_verify_fails_when_ssh_is_not_public() {
  local output

  reset_fake_bin
  write_fake_command ufw <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  'status')
    cat <<'OUT'
Status: active
OUT
    ;;
  'status verbose')
    cat <<'OUT'
Status: active
Logging: off
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip
OUT
    ;;
  'status numbered')
    cat <<'OUT'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 41641/udp                  ALLOW IN    Anywhere
[ 2] 22/tcp                     ALLOW IN    100.64.0.0/10
[ 3] 8080/tcp                   ALLOW IN    100.64.0.0/10
[ 4] 9222/tcp                   ALLOW IN    100.64.0.0/10
[ 5] 3000/tcp                   ALLOW IN    100.64.0.0/10
OUT
    ;;
  *)
    exit 0
    ;;
esac
EOF

  if output=$(run_script --backend ufw --verify 2>&1); then
    fail 'expected ufw verification to fail when SSH is not public'
  fi

  assert_contains "${output}" 'verification failed: missing tcp/22 allow rule for 100.64.0.0/10'
}

test_iptables_dry_run_logs_expected_rules() {
  local output

  reset_fake_bin
  write_fake_command iptables <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  output=$(run_script --dry-run --backend iptables 2>&1)

  assert_contains "${output}" 'dry-run: would snapshot current iptables state under'
  assert_contains "${output}" 'using firewall backend: iptables'
  assert_contains "${output}" 'ssh note: tcp/22 restricted to 100.64.0.0/10 (Tailscale only)'
  assert_contains "${output}" 'tailscale subnet allowlist: dev ports stay restricted to 100.64.0.0/10'
  assert_contains "${output}" 'DRY-RUN: iptables -w -N DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -F DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -I INPUT 1 -j DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -i lo -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -m conntrack --ctstate RELATED\,ESTABLISHED -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p udp --dport 41641 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp --dport 22 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 8080 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 9222 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -p tcp -s 100.64.0.0/10 --dport 3000 -j ACCEPT'
  assert_contains "${output}" 'DRY-RUN: iptables -w -A DWS_FIREWALL_INPUT -j DROP'
  assert_contains "${output}" 'drop all other inbound IPv4 traffic'
  assert_contains "${output}" 'dry-run: verification skipped; run dws-firewall.sh --backend iptables --verify after applying'
  assert_contains "${output}" 'firewall configuration complete'
}

test_iptables_verify_passes_when_chain_is_first() {
  local output

  reset_fake_bin
  write_fake_command iptables <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  '-w -S INPUT')
    cat <<'OUT'
-P INPUT ACCEPT
-A INPUT -j DWS_FIREWALL_INPUT
-A INPUT -p icmp -j ACCEPT
OUT
    ;;
  '-w -S DWS_FIREWALL_INPUT')
    cat <<'OUT'
-N DWS_FIREWALL_INPUT
-A DWS_FIREWALL_INPUT -i lo -j ACCEPT
-A DWS_FIREWALL_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DWS_FIREWALL_INPUT -p udp -m udp --dport 41641 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 8080 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 9222 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 3000 -j ACCEPT
-A DWS_FIREWALL_INPUT -j DROP
OUT
    ;;
  *)
    exit 0
    ;;
esac
EOF

  output=$(run_script --backend iptables --verify 2>&1)

  assert_contains "${output}" 'using firewall backend: iptables'
  assert_contains "${output}" 'starting firewall verification: iptables'
  assert_contains "${output}" 'verification passed: DWS_FIREWALL_INPUT is the first INPUT rule'
  assert_contains "${output}" 'verification passed: tcp/22 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: tcp/8080 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: tcp/9222 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: tcp/3000 is restricted to 100.64.0.0/10'
  assert_contains "${output}" 'verification passed: all other inbound IPv4 traffic drops at the end of DWS_FIREWALL_INPUT'
  assert_contains "${output}" 'verification passed: DWS_FIREWALL_INPUT rule set matches the repo policy'
  assert_contains "${output}" 'firewall verification complete'
}

test_iptables_verify_fails_when_chain_drifts_from_repo_policy() {
  local output

  reset_fake_bin
  write_fake_command iptables <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  '-w -S INPUT')
    cat <<'OUT'
-P INPUT ACCEPT
-A INPUT -j DWS_FIREWALL_INPUT
OUT
    ;;
  '-w -S DWS_FIREWALL_INPUT')
    cat <<'OUT'
-N DWS_FIREWALL_INPUT
-A DWS_FIREWALL_INPUT -i lo -j ACCEPT
-A DWS_FIREWALL_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DWS_FIREWALL_INPUT -p udp -m udp --dport 41641 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 8080 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 9222 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 3000 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp --dport 8443 -j ACCEPT
-A DWS_FIREWALL_INPUT -j DROP
OUT
    ;;
  *)
    exit 0
    ;;
esac
EOF

  if output=$(run_script --backend iptables --verify 2>&1); then
    fail 'expected iptables verification to fail when the managed chain drifts from the repo policy'
  fi

  assert_contains "${output}" 'verification failed: DWS_FIREWALL_INPUT rule count does not match the repo policy'
}

test_iptables_verify_fails_when_ssh_rule_is_not_public() {
  local output

  reset_fake_bin
  write_fake_command iptables <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  '-w -S INPUT')
    cat <<'OUT'
-P INPUT ACCEPT
-A INPUT -j DWS_FIREWALL_INPUT
OUT
    ;;
  '-w -S DWS_FIREWALL_INPUT')
    cat <<'OUT'
-N DWS_FIREWALL_INPUT
-A DWS_FIREWALL_INPUT -i lo -j ACCEPT
-A DWS_FIREWALL_INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DWS_FIREWALL_INPUT -p udp -m udp --dport 41641 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 22 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 8080 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 9222 -j ACCEPT
-A DWS_FIREWALL_INPUT -p tcp -m tcp -s 100.64.0.0/10 --dport 3000 -j ACCEPT
-A DWS_FIREWALL_INPUT -j DROP
OUT
    ;;
  *)
    exit 0
    ;;
esac
EOF

  if output=$(run_script --backend iptables --verify 2>&1); then
    fail 'expected iptables verification to fail when the SSH rule is not public'
  fi

  assert_contains "${output}" 'verification failed: tcp/22 rule does not match the expected public ingress policy'
}

test_rollback_dry_run_uses_latest_snapshot() {
  local snapshot output

  reset_fake_bin
  write_fake_command ufw <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  snapshot="${STATE_DIR}/snapshots/20260423T000000Z-ufw"
  mkdir -p "${snapshot}/root/etc/default" "${snapshot}/root/etc/ufw" "${STATE_DIR}"
  printf 'ufw\n' >"${snapshot}/backend.txt"
  printf 'active\n' >"${snapshot}/ufw-state.txt"
  printf 'present\t/etc/default/ufw\n' >"${snapshot}/files.tsv"
  printf 'present\t/etc/ufw/ufw.conf\n' >>"${snapshot}/files.tsv"
  printf 'defaults\n' >"${snapshot}/root/etc/default/ufw"
  printf 'enabled=yes\n' >"${snapshot}/root/etc/ufw/ufw.conf"
  ln -sfn "${snapshot}" "${STATE_DIR}/latest"
  ln -sfn "${snapshot}" "${STATE_DIR}/latest-ufw"

  output=$(run_script --dry-run --rollback 2>&1)

  assert_contains "${output}" "using rollback snapshot: ${snapshot}"
  assert_contains "${output}" "rolling back ufw from snapshot: ${snapshot}"
  assert_contains "${output}" "DRY-RUN: mkdir -p -- /etc/default"
  assert_contains "${output}" "DRY-RUN: cp -a -- ${snapshot}/root/etc/default/ufw /etc/default/ufw"
  assert_contains "${output}" "DRY-RUN: cp -a -- ${snapshot}/root/etc/ufw/ufw.conf /etc/ufw/ufw.conf"
  assert_contains "${output}" 'DRY-RUN: ufw --force enable'
  assert_contains "${output}" 'dry-run: rollback status inspection skipped for ufw'
  assert_contains "${output}" 'firewall rollback complete'
}

trap cleanup EXIT

test_script_is_executable
test_ufw_dry_run_logs_expected_rules
test_ufw_verify_passes_when_rules_match_policy
test_ufw_verify_fails_when_ssh_is_not_public
test_iptables_dry_run_logs_expected_rules
test_iptables_verify_passes_when_chain_is_first
test_iptables_verify_fails_when_chain_drifts_from_repo_policy
test_iptables_verify_fails_when_ssh_rule_is_not_public
test_rollback_dry_run_uses_latest_snapshot
printf 'ok\n'
