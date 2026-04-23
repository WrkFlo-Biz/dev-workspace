#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-tailscale-diag.sh"

ORIG_PATH="${PATH}"
ORIG_HOME="${HOME}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) fail "expected output to omit: $needle" ;;
    *) ;;
  esac
}

write_fake_command() {
  local name="$1" body="$2"
  local path="${FAKE_BIN}/${name}"

  cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${path}"
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-tailscale-diag-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export NO_COLOR=1
  export DWS_TAILSCALE_KNOWN_PEERS='mac=100.78.207.22 iphone=100.88.249.22 gateway=100.126.194.98'

  mkdir -p "${FAKE_BIN}" "${HOME}"

  write_fake_command hostname '
if [ "${1:-}" = "-s" ]; then
  printf "dev-workspace-vm\n"
  exit 0
fi
printf "dev-workspace-vm.example.net\n"
'

  write_fake_command date '
if [ "${1:-}" = "-u" ]; then
  printf "2026-04-23 12:00:00 UTC\n"
  exit 0
fi
printf "2026-04-23 12:00:00 UTC\n"
'

  write_fake_command timeout '
seconds="${1:-}"
shift || true
exec "$@"
'

  write_fake_command sudo '
if [ "${1:-}" = "-n" ]; then
  shift
fi
FAKE_SUDO=1 exec "$@"
'

  write_fake_command tailscale '
case "${1:-} ${2:-} ${3:-}" in
  "status --json ")
    cat <<'\''EOF'\''
{
  "BackendState": "Running",
  "Self": {
    "TailscaleIPs": ["100.117.16.63"],
    "HostName": "dev-workspace-vm"
  },
  "CurrentTailnet": {
    "Name": "wrk-flo.github",
    "MagicDNSEnabled": true
  },
  "Health": [],
  "Peer": {
    "mac": {
      "HostName": "mosess-macbook-air-3",
      "DNSName": "mosess-macbook-air-3.tail18ff5a.ts.net.",
      "OS": "macOS",
      "Online": true,
      "Active": true,
      "Relay": "dfw",
      "CurAddr": "72.24.145.11:50296",
      "TailscaleIPs": ["100.78.207.22"]
    },
    "iphone": {
      "HostName": "iphone-15-pro-max",
      "DNSName": "iphone-15-pro-max.tail18ff5a.ts.net.",
      "OS": "iOS",
      "Online": true,
      "Active": false,
      "Relay": "den",
      "CurAddr": "",
      "TailscaleIPs": ["100.88.249.22"]
    },
    "gateway": {
      "HostName": "openclaw-gateway-vm",
      "DNSName": "openclaw-gateway-vm.tail18ff5a.ts.net.",
      "OS": "linux",
      "Online": true,
      "Active": true,
      "Relay": "iad",
      "CurAddr": "20.124.180.8:41641",
      "TailscaleIPs": ["100.126.194.98"]
    }
  }
}
EOF
    exit 0
    ;;
  "status --peers ")
    cat <<'\''EOF'\''
100.117.16.63   dev-workspace-vm      Wrk-Flo@  linux  -
100.88.249.22   iphone-15-pro-max     Wrk-Flo@  iOS    active; relay "den"
100.78.207.22   mosess-macbook-air-3  Wrk-Flo@  macOS  active; direct 72.24.145.11:50296
100.126.194.98  openclaw-gateway-vm   Wrk-Flo@  linux  active; direct 20.124.180.8:41641
EOF
    exit 0
    ;;
  "ip -4 ")
    printf "100.117.16.63\n"
    exit 0
    ;;
  "version --json ")
    cat <<'\''EOF'\''
{
  "majorMinorPatch": "1.96.4",
  "short": "1.96.4",
  "long": "1.96.4-t8cf541dfd-g62bc84ce7",
  "gitCommit": "8cf541dfd1e0a97096c01cb775d5e26336f3bc6c"
}
EOF
    exit 0
    ;;
  "update --dry-run ")
    if [ "${FAKE_SUDO:-0}" = "1" ]; then
      printf "already running stable version 1.96.4; no update needed\n"
      exit 0
    fi
    printf "must be root; use sudo\n"
    exit 1
    ;;
  "ping -c 1")
    case "${4:-}" in
      100.78.207.22)
        printf "pong from mosess-macbook-air-3 (100.78.207.22) via 72.24.145.11:50296 in 70ms\n"
        exit 0
        ;;
      100.88.249.22)
        printf "pong from iphone-15-pro-max (100.88.249.22) via DERP(den) in 1.204s\n"
        printf "direct connection not established\n"
        exit 1
        ;;
      100.126.194.98)
        printf "pong from openclaw-gateway-vm (100.126.194.98) via 20.124.180.8:41641 in 185ms\n"
        exit 0
        ;;
    esac
    ;;
esac
exit 1
'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset NO_COLOR DWS_TAILSCALE_KNOWN_PEERS

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

test_tailscale_diag_reports_direct_and_derp_peers() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  output=$("${SCRIPT}" 2>&1)

  assert_contains "${output}" "Tailscale Diagnostic Report"
  assert_contains "${output}" "PASS tailscale status Running (100.117.16.63 on wrk-flo.github; MagicDNS enabled)"
  assert_contains "${output}" "PASS tailscale health clear"
  assert_contains "${output}" "PASS mac: mosess-macbook-air-3 (100.78.207.22) macOS direct 72.24.145.11:50296 70ms"
  assert_contains "${output}" "PASS iphone: iphone-15-pro-max (100.88.249.22) iOS DERP den 1.204s"
  assert_contains "${output}" "PASS gateway: openclaw-gateway-vm (100.126.194.98) linux direct 20.124.180.8:41641 185ms"
  assert_contains "${output}" "PASS tailscale version 1.96.4 (1.96.4-t8cf541dfd-g62bc84ce7)"
  assert_contains "${output}" "PASS updates already running stable version 1.96.4; no update needed"
  assert_contains "${output}" "overall: PASS"
  assert_contains "${output}" "direct peers: 2"
  assert_contains "${output}" "derp peers: 1"
  assert_contains "${output}" "unreachable peers: 0"
  assert_not_contains "${output}" "WARN "
  assert_not_contains "${output}" "FAIL "

  cleanup_fixture
  trap - EXIT
}

test_tailscale_diag_reports_failures_and_update_warning() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_fake_command tailscale '
case "${1:-} ${2:-} ${3:-}" in
  "status --json ")
    cat <<'\''EOF'\''
{
  "BackendState": "Running",
  "Self": {
    "TailscaleIPs": ["100.117.16.63"],
    "HostName": "dev-workspace-vm"
  },
  "CurrentTailnet": {
    "Name": "wrk-flo.github",
    "MagicDNSEnabled": true
  },
  "Health": ["wireguard handshake stale"],
  "Peer": {
    "mac": {
      "HostName": "mosess-macbook-air-3",
      "DNSName": "mosess-macbook-air-3.tail18ff5a.ts.net.",
      "OS": "macOS",
      "Online": true,
      "Active": true,
      "Relay": "dfw",
      "CurAddr": "72.24.145.11:50296",
      "TailscaleIPs": ["100.78.207.22"]
    }
  }
}
EOF
    exit 0
    ;;
  "ip -4 ")
    printf "100.117.16.63\n"
    exit 0
    ;;
  "version --json ")
    cat <<'\''EOF'\''
{
  "short": "1.96.4",
  "long": "1.96.4-t8cf541dfd-g62bc84ce7"
}
EOF
    exit 0
    ;;
  "update --dry-run ")
    if [ "${FAKE_SUDO:-0}" = "1" ]; then
      printf "would update from stable 1.96.4 to 1.96.5\n"
      exit 0
    fi
    printf "must be root; use sudo\n"
    exit 1
    ;;
  "ping -c 1")
    case "${4:-}" in
      100.78.207.22)
        printf "pong from mosess-macbook-air-3 (100.78.207.22) via 72.24.145.11:50296 in 70ms\n"
        exit 0
        ;;
      100.88.249.22)
        printf "no matching peer\n"
        exit 1
        ;;
      100.126.194.98)
        printf "timeout waiting for pong\n"
        exit 1
        ;;
    esac
    ;;
esac
exit 1
'

  if output=$("${SCRIPT}" 2>&1); then
    fail "expected degraded tailscale diagnostics to exit non-zero"
  fi

  assert_contains "${output}" "WARN tailscale health wireguard handshake stale"
  assert_contains "${output}" "PASS mac: mosess-macbook-air-3 (100.78.207.22) macOS direct 72.24.145.11:50296 70ms"
  assert_contains "${output}" "FAIL iphone: 100.88.249.22 unreachable (no matching peer)"
  assert_contains "${output}" "FAIL gateway: 100.126.194.98 unreachable (timeout waiting for pong)"
  assert_contains "${output}" "WARN updates would update from stable 1.96.4 to 1.96.5"
  assert_contains "${output}" "overall: FAIL"
  assert_contains "${output}" "unreachable peers: 2"

  cleanup_fixture
  trap - EXIT
}

test_tailscale_diag_reports_direct_and_derp_peers
test_tailscale_diag_reports_failures_and_update_warning
printf 'ok\n'
