#!/usr/bin/env bash
# dws-termius-verify.sh — verify Termius/phone connectivity from the VM side
set -euo pipefail

PHONE_IP="${DWS_PHONE_IP:-100.88.249.22}"
MAC_IP="${DWS_MAC_IP:-100.78.207.22}"
SSH_CONFIG="/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf"
TERMIUS_KEY_LABEL="termius"

pass=0
fail=0
warn=0

check() {
  local label="$1" result="$2"
  if [ "$result" = "PASS" ]; then
    printf "  PASS  %s\n" "$label"
    pass=$((pass + 1))
  elif [ "$result" = "WARN" ]; then
    printf "  WARN  %s\n" "$label"
    warn=$((warn + 1))
  else
    printf "  FAIL  %s\n" "$label"
    fail=$((fail + 1))
  fi
}

echo "Termius / Phone Connectivity Verification"
echo "time: $(date -u "+%Y-%m-%d %H:%M:%S UTC")"
echo ""

# 1. Tailscale sees phone peer
if tailscale status 2>/dev/null | grep -q "$PHONE_IP"; then
  check "phone peer visible in tailscale ($PHONE_IP)" "PASS"
else
  check "phone peer visible in tailscale ($PHONE_IP)" "WARN"
fi

# 2. Phone is pingable (may timeout if phone is sleeping)
if tailscale ping --timeout=5s "$PHONE_IP" >/dev/null 2>&1; then
  check "phone responds to tailscale ping" "PASS"
else
  check "phone responds to tailscale ping (may be asleep)" "WARN"
fi

# 3. SSH config allows pubkey auth
if grep -q "PubkeyAuthentication yes" "$SSH_CONFIG" 2>/dev/null; then
  check "sshd allows pubkey authentication" "PASS"
else
  check "sshd allows pubkey authentication" "FAIL"
fi

# 4. Password auth is disabled
if grep -q "PasswordAuthentication no" "$SSH_CONFIG" 2>/dev/null; then
  check "sshd password auth disabled" "PASS"
else
  check "sshd password auth disabled" "FAIL"
fi

# 5. ClientAliveInterval configured
if grep -q "ClientAliveInterval" "$SSH_CONFIG" 2>/dev/null; then
  check "sshd keepalive configured" "PASS"
else
  check "sshd keepalive configured" "FAIL"
fi

# 6. Termius key exists in authorized_keys
if grep -qi "$TERMIUS_KEY_LABEL" ~/.ssh/authorized_keys 2>/dev/null; then
  check "termius key in authorized_keys" "PASS"
else
  # Check for any ed25519 keys as fallback
  if grep -c "ssh-ed25519" ~/.ssh/authorized_keys 2>/dev/null | grep -q "[1-9]"; then
    check "ed25519 key(s) in authorized_keys (no termius label found)" "WARN"
  else
    check "termius key in authorized_keys" "FAIL"
  fi
fi

# 7. SSH port is listening
if ss -tlnp 2>/dev/null | grep -q ":22 "; then
  check "ssh listening on port 22" "PASS"
else
  check "ssh listening on port 22" "FAIL"
fi

# 8. Recent phone auth in journal (last 24h)
if journalctl -u ssh --since "24 hours ago" --no-pager 2>/dev/null | grep -q "$PHONE_IP"; then
  check "phone SSH auth seen in last 24h" "PASS"
else
  check "phone SSH auth seen in last 24h (connect from phone to verify)" "WARN"
fi

# 9. Mac peer is reachable (sanity check)
if tailscale ping --timeout=3s "$MAC_IP" >/dev/null 2>&1; then
  check "mac peer reachable ($MAC_IP)" "PASS"
else
  check "mac peer reachable ($MAC_IP)" "WARN"
fi

echo ""
echo "overall: $pass passed, $fail failed, $warn warnings"

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "ACTION REQUIRED: fix failures before claiming phone access is verified"
  exit 1
fi
