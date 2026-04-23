#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/dws-health.sh"

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

strip_ansi() {
  sed -E 's/\x1B\[[0-9;]*m//g'
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
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-health-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export NO_COLOR=1
  export AZURE_OPENAI_API_KEY="test-key"
  export MAC_TAILNET_IP="100.78.207.22"
  export PHONE_TAILNET_IP="100.88.249.22"
  export GATEWAY_TAILNET_IP="100.126.194.98"
  export MAC_GUI_URL="http://100.78.207.22:9223"
  export MAC_CDP_URL="http://100.78.207.22:9222"
  export DWS_SSH_HARDENING_CONF="${FIXTURE_ROOT}/01-wrkflo-hardening.conf"

  mkdir -p "${FAKE_BIN}" "${HOME}"
  cat >"${DWS_SSH_HARDENING_CONF}" <<'EOF'
PasswordAuthentication no
PermitRootLogin no
ClientAliveInterval 30
EOF

  write_fake_command hostname '
if [ "${1:-}" = "-s" ]; then
  printf "dev-workspace-vm\n"
  exit 0
fi
printf "dev-workspace-vm.example.net\n"
'

  write_fake_command date '
printf "2026-04-23 12:00:00 UTC\n"
'

  write_fake_command uptime '
if [ "${1:-}" = "-p" ]; then
  printf "up 3 hours\n"
  exit 0
fi
printf " 12:00:00 up 3 hours,  1 user,  load average: 0.50, 0.30, 0.20\n"
'

  write_fake_command df '
cat <<'\''EOF'\''
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       100G   40G   60G  40% /
EOF
'

  write_fake_command free '
if [ "${1:-}" = "-h" ]; then
  cat <<'\''EOF'\''
               total        used        free      shared  buff/cache   available
Mem:            16Gi       4.0Gi       8.0Gi       1.0Mi       4.0Gi        12Gi
Swap:             0B          0B          0B
EOF
  exit 0
fi
cat <<'\''EOF'\''
               total        used        free      shared  buff/cache   available
Mem:         16000000     4000000     8000000        1000     4000000    12000000
Swap:               0           0           0
EOF
'

  write_fake_command systemctl '
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ]; then
  case "${3:-}" in
    dws-task-monitor.service)
      printf "active\n"
      exit 0
      ;;
    dws-sessions-init.service)
      printf "active\n"
      exit 0
      ;;
  esac
fi
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show" ] && [ "${4:-}" = "--property=SubState" ] && [ "${5:-}" = "--value" ]; then
  case "${3:-}" in
    dws-task-monitor.service)
      printf "running\n"
      exit 0
      ;;
    dws-sessions-init.service)
      printf "exited\n"
      exit 0
      ;;
  esac
fi
exit 1
'

  write_fake_command curl '
case "${*: -1}" in
  http://127.0.0.1:8100/v1/workspace/health) printf "200" ;;
  http://100.78.207.22:9223) printf "200" ;;
  http://100.78.207.22:9222) printf "200" ;;
  *) printf "000" ;;
esac
'

  write_fake_command codex '
printf "codex 1.2.3\n"
'

  write_fake_command claude '
printf "claude 4.6.0\n"
'

  write_fake_command gh '
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf "Logged in to github.com account moses\n"
  exit 0
fi
exit 1
'

  write_fake_command az '
if [ "${1:-}" = "account" ] && [ "${2:-}" = "show" ]; then
  printf "moses@example.com\tWrkFlo Subscription\n"
  exit 0
fi
exit 1
'

  write_fake_command ufw '
cat <<'\''EOF'\''
Status: active
EOF
'

  write_fake_command tailscale '
case "${1:-}" in
  status)
    if [ "${2:-}" = "--peers" ]; then
      cat <<'\''EOF'\''
100.78.207.22  mosess-macbook-air-3  Wrk-Flo@  macOS   active; direct 100.78.207.22:41641
100.88.249.22  iphone-15-pro-max     Wrk-Flo@  iOS     active; relay "ord"
100.126.194.98 openclaw-gateway-vm   Wrk-Flo@  linux   active; direct 20.124.180.8:41641
EOF
      exit 0
    fi
    exit 0
    ;;
  ping)
    case "${4:-}" in
      100.78.207.22)
        printf "pong from mosess-macbook-air-3 (100.78.207.22) via 100.78.207.22:41641 in 12ms\n"
        exit 0
        ;;
      100.88.249.22)
        printf "pong from iphone-15-pro-max (100.88.249.22) via DERP(ord) in 85ms\n"
        exit 0
        ;;
      100.126.194.98)
        printf "pong from openclaw-gateway-vm (100.126.194.98) via 20.124.180.8:41641 in 185ms\n"
        exit 0
        ;;
    esac
    exit 1
    ;;
  ip)
    if [ "${2:-}" = "-4" ]; then
      printf "100.117.16.63\n"
      exit 0
    fi
    ;;
esac
exit 1
'

  write_fake_command tmux '
if [ "${1:-}" = "ls" ]; then
  printf "orchestrator: 1 windows (created Thu Apr 23 12:00:00 2026) [80x24]\n"
  exit 0
fi
if [ "${1:-}" = "-V" ]; then
  printf "tmux 3.4\n"
  exit 0
fi
exit 1
'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset NO_COLOR AZURE_OPENAI_API_KEY MAC_TAILNET_IP PHONE_TAILNET_IP GATEWAY_TAILNET_IP \
    MAC_GUI_URL MAC_CDP_URL DWS_SSH_HARDENING_CONF

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

test_text_output_includes_requested_checks() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  output=$(bash "${SCRIPT}" 2>&1 | strip_ansi)
  assert_contains "${output}" "== Services =="
  assert_contains "${output}" "task monitor active (running)"
  assert_contains "${output}" "sessions init active (exited)"
  assert_contains "${output}" "== Security =="
  assert_contains "${output}" "ssh config   ok"
  assert_contains "${output}" "firewall     active  ufw"
  assert_contains "${output}" "== Tailnet =="
  assert_contains "${output}" "connected    yes"
  assert_contains "${output}" "mac          12ms  100.78.207.22"
  assert_contains "${output}" "phone        85ms  100.88.249.22"
  assert_contains "${output}" "gateway      185ms  100.126.194.98"

  cleanup_fixture
  trap - EXIT
}

test_json_output_includes_requested_checks() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  output=$(bash "${SCRIPT}" --json 2>&1 | strip_ansi)
  assert_contains "${output}" '"dws_task_monitor":{"state":"active (running)","healthy":true}'
  assert_contains "${output}" '"dws_sessions_init":{"state":"active (exited)","healthy":true}'
  assert_contains "${output}" '"ssh_hardening":{"path":"'
  assert_contains "${output}" '"state":"ok","healthy":true'
  assert_contains "${output}" '"firewall":{"backend":"ufw","state":"active","detail":"","healthy":true}'
  assert_contains "${output}" '"mac":{"ip":"100.78.207.22","state":"reachable","latency":"12ms","reachable":true}'
  assert_contains "${output}" '"phone":{"ip":"100.88.249.22","state":"reachable","latency":"85ms","reachable":true}'
  assert_contains "${output}" '"gateway":{"ip":"100.126.194.98","state":"reachable","latency":"185ms","reachable":true}'

  cleanup_fixture
  trap - EXIT
}

test_text_output_includes_requested_checks
test_json_output_includes_requested_checks

printf 'PASS: %s\n' "$(basename "$0")"
