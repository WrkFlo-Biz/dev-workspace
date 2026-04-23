#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-health-full.sh"

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
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-health-full-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export NO_COLOR=1
  export DWS_HEALTH_REQUIRED_PORTS="22 8080 9222"
  export DWS_HEALTH_LOAD_AVERAGES="0.50 0.30 0.20"

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

  write_fake_command df '
case "${1:-}" in
  -P)
    cat <<'\''EOF'\''
Filesystem     1024-blocks   Used Available Capacity Mounted on
/dev/root         1000000 400000    600000       40% /
EOF
    ;;
  -hP)
    cat <<'\''EOF'\''
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       100G   40G   60G  40% /
EOF
    ;;
  *)
    exit 1
    ;;
esac
'

  write_fake_command free '
case "${1:-}" in
  -h)
    cat <<'\''EOF'\''
               total        used        free      shared  buff/cache   available
Mem:            16Gi       4.0Gi       8.0Gi       1.0Mi       4.0Gi        12Gi
Swap:             0B          0B          0B
EOF
    ;;
  "")
    cat <<'\''EOF'\''
               total        used        free      shared  buff/cache   available
Mem:         16000000     4000000     8000000        1000     4000000    12000000
Swap:               0           0           0
EOF
    ;;
  *)
    exit 1
    ;;
esac
'

  write_fake_command getconf '
if [ "${1:-}" = "_NPROCESSORS_ONLN" ]; then
  printf "4\n"
  exit 0
fi
exit 1
'

  write_fake_command uptime '
printf " 12:00:00 up 10 days,  1 user,  load average: 0.50, 0.30, 0.20\n"
'

  write_fake_command tailscale '
case "${1:-}" in
  status) exit 0 ;;
  ip)
    if [ "${2:-}" = "-4" ]; then
      printf "100.117.16.63\n"
      exit 0
    fi
    ;;
esac
exit 1
'

  write_fake_command systemctl '
if [ "${1:-}" = "is-active" ] && [ "${2:-}" = "--quiet" ] && [ "${3:-}" = "ssh.service" ]; then
  exit 0
fi
exit 1
'

  write_fake_command service '
exit 1
'

  write_fake_command pgrep '
exit 1
'

  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  printf "orch|2|1\nworker|1|0\n"
  exit 0
fi
exit 1
'

  write_fake_command python3 '
printf "Python 3.12.4\n"
'

  write_fake_command node '
printf "v22.11.0\n"
'

  write_fake_command git '
printf "git version 2.44.0\n"
'

  write_fake_command ufw '
cat <<'\''EOF'\''
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 8080/tcp                   ALLOW IN    Anywhere
[ 3] 9222/tcp                   ALLOW IN    Anywhere
EOF
'

  write_fake_command ss '
cat <<'\''EOF'\''
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=100,fd=3))
LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("python3",pid=101,fd=4))
LISTEN 0 4096 0.0.0.0:9222 0.0.0.0:* users:(("chrome",pid=102,fd=5))
EOF
'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  export HOME="${ORIG_HOME}"
  unset NO_COLOR DWS_HEALTH_REQUIRED_PORTS DWS_HEALTH_LOAD_AVERAGES

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

test_health_report_passes_when_vm_looks_healthy() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  output=$("${SCRIPT}" 2>&1)

  assert_contains "${output}" "VM Health Report"
  assert_contains "${output}" "PASS tailscale connected (100.117.16.63)"
  assert_contains "${output}" "PASS ssh daemon active (ssh.service)"
  assert_contains "${output}" "PASS tmux sessions alive: 2 total (1 attached, 1 detached)"
  assert_contains "${output}" "PASS disk usage 40% (40G/100G used, 60G free)"
  assert_contains "${output}" "PASS memory usage 25% (4.0Gi/16Gi used, 12Gi available)"
  assert_contains "${output}" "PASS cpu load 0.50 0.30 0.20 on 4 cores"
  assert_contains "${output}" "PASS python Python 3.12.4"
  assert_contains "${output}" "PASS node v22.11.0"
  assert_contains "${output}" "PASS git git version 2.44.0"
  assert_contains "${output}" "PASS firewall ufw active"
  assert_contains "${output}" "PASS port 22 listening on 0.0.0.0:22"
  assert_contains "${output}" "PASS port 8080 listening on 127.0.0.1:8080"
  assert_contains "${output}" "PASS port 9222 listening on 0.0.0.0:9222"
  assert_contains "${output}" "overall: PASS"
  assert_contains "${output}" "fail: 0"
  assert_not_contains "${output}" "WARN "
  assert_not_contains "${output}" "FAIL "

  cleanup_fixture
  trap - EXIT
}

test_health_report_fails_when_ports_or_services_are_missing() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  write_fake_command tailscale '
if [ "${1:-}" = "status" ]; then
  exit 1
fi
exit 1
'

  write_fake_command systemctl '
exit 1
'

  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  exit 0
fi
exit 1
'

  write_fake_command ufw '
printf "Status: inactive\n"
'

  write_fake_command ss '
cat <<'\''EOF'\''
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=100,fd=3))
EOF
'

  if output=$("${SCRIPT}" 2>&1); then
    fail "expected degraded health report to exit non-zero"
  fi

  assert_contains "${output}" "FAIL tailscale not connected"
  assert_contains "${output}" "FAIL ssh daemon not running"
  assert_contains "${output}" "WARN no tmux sessions running"
  assert_contains "${output}" "WARN firewall ufw inactive"
  assert_contains "${output}" "PASS port 22 listening on 0.0.0.0:22"
  assert_contains "${output}" "FAIL port 8080 not listening"
  assert_contains "${output}" "FAIL port 9222 not listening"
  assert_contains "${output}" "overall: FAIL"
  assert_not_contains "${output}" "fail: 0"

  cleanup_fixture
  trap - EXIT
}

test_health_report_passes_when_vm_looks_healthy
test_health_report_fails_when_ports_or_services_are_missing
printf 'ok\n'
