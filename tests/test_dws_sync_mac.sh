#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-sync-mac.sh"
ORIG_PATH="${PATH}"
FIXTURE_ROOT=""

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
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null && fail "unexpected output: $needle"
}

write_fake_command() {
  local name="$1" body="$2"
  local path="${FAKE_BIN}/${name}"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "$path"
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-sync-mac-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  mkdir -p "${FAKE_BIN}"

  export PATH="${FAKE_BIN}:${ORIG_PATH}"
  export MAC_SSH_HOST="tester-mac"
  unset TEST_RSYNC_REPO_DRIFT TEST_RSYNC_CHROME_DRIFT TEST_RSYNC_BRIDGES_DRIFT

  write_fake_command ssh '
cmd="${*: -1}"

case "$cmd" in
  *"printf %s \"\$HOME\""*)
    printf "/Users/tester"
    exit 0
    ;;
  "id -u")
    printf "501\n"
    exit 0
    ;;
  *"[ -d /Users/tester/dev-workspace ]"*)
    exit 0
    ;;
  *"[ -d /Users/tester/Library/LaunchAgents ]"*)
    exit 0
    ;;
  *"command -v tailscale"*)
    exit 0
    ;;
  *"tailscale ip -4"*)
    printf "100.78.207.22\n"
    exit 0
    ;;
  *"command -v socat"*)
    exit 0
    ;;
  *"Google\\\\ Chrome.app"*|*"Google Chrome.app"*)
    exit 0
    ;;
  *"Hammerspoon.app"*)
    exit 0
    ;;
  *".hammerspoon/init.lua"*)
    exit 0
    ;;
  *"launchctl print gui/"*"com.wrkflo.chrome-cdp"*)
    exit 0
    ;;
  *"launchctl print gui/"*"com.wrkflo.mac-bridges"*)
    exit 0
    ;;
  *"pgrep -x Hammerspoon"*)
    exit 0
    ;;
  *"http://127.0.0.1:9222/json/version"*)
    printf "{}\n"
    exit 0
    ;;
  *"http://127.0.0.1:9223/apps"*)
    printf "{}\n"
    exit 0
    ;;
esac

printf "unexpected ssh command: %s\n" "$cmd" >&2
exit 1'

  write_fake_command rsync '
consume_stdin=0
for arg in "$@"; do
  if [ "$arg" = "--files-from=-" ]; then
    consume_stdin=1
  fi
done

if [ "$consume_stdin" -eq 1 ]; then
  cat >/dev/null
fi

dest="${*: -1}"
case "$dest" in
  *":/Users/tester/dev-workspace/")
    [ -n "${TEST_RSYNC_REPO_DRIFT:-}" ] && printf "%s\n" "${TEST_RSYNC_REPO_DRIFT}"
    exit 0
    ;;
  *":/Users/tester/Library/LaunchAgents/com.wrkflo.chrome-cdp.plist")
    [ -n "${TEST_RSYNC_CHROME_DRIFT:-}" ] && printf "%s\n" "${TEST_RSYNC_CHROME_DRIFT}"
    exit 0
    ;;
  *":/Users/tester/Library/LaunchAgents/com.wrkflo.mac-bridges.plist")
    [ -n "${TEST_RSYNC_BRIDGES_DRIFT:-}" ] && printf "%s\n" "${TEST_RSYNC_BRIDGES_DRIFT}"
    exit 0
    ;;
esac

printf "unexpected rsync destination: %s\n" "$dest" >&2
exit 1'

  write_fake_command curl '
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done

case "$url" in
  *":9222/json/version"|*":9223/apps")
    printf "{}\n"
    exit 0
    ;;
esac

printf "unexpected curl url: %s\n" "$url" >&2
exit 1'
}

cleanup_fixture() {
  export PATH="${ORIG_PATH}"
  unset MAC_SSH_HOST TEST_RSYNC_REPO_DRIFT TEST_RSYNC_CHROME_DRIFT TEST_RSYNC_BRIDGES_DRIFT

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

test_verify_passes_when_in_sync() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  output=$(bash "${SCRIPT}" verify 2>&1)
  assert_contains "${output}" "[ok] repo parity"
  assert_contains "${output}" "[ok] launch agent parity: com.wrkflo.chrome-cdp"
  assert_contains "${output}" "[ok] launch agent parity: com.wrkflo.mac-bridges"
  assert_contains "${output}" "[ok] Mac sync and relay checks passed"
  assert_not_contains "${output}" "[warn] repo parity"

  cleanup_fixture
  trap - EXIT
}

test_verify_reports_drift_without_syncing() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  export TEST_RSYNC_REPO_DRIFT=">f.st...... bin/dws-sync-mac.sh"
  export TEST_RSYNC_CHROME_DRIFT=">f.st...... com.wrkflo.chrome-cdp.plist"

  if output=$(bash "${SCRIPT}" verify 2>&1); then
    fail "expected verify to fail when repo or plist drift is present"
  fi

  assert_contains "${output}" "verify is read-only: drift is reported, no files are copied"
  assert_contains "${output}" "[warn] repo parity: run dws-sync-mac.sh push to sync VM -> Mac repo"
  assert_contains "${output}" "  >f.st...... bin/dws-sync-mac.sh"
  assert_contains "${output}" "[warn] launch agent parity: com.wrkflo.chrome-cdp: run dws-sync-mac.sh pull to snapshot installed plist"
  assert_contains "${output}" "  >f.st...... com.wrkflo.chrome-cdp.plist"
  assert_contains "${output}" "[warn] dws-sync-mac.sh push"
  assert_contains "${output}" "[warn] dws-sync-mac.sh pull"
  assert_not_contains "${output}" "pushed VM scripts to"
  assert_not_contains "${output}" "pulled Mac LaunchAgent configs into mac-setup/"

  cleanup_fixture
  trap - EXIT
}

test_verify_passes_when_in_sync
test_verify_reports_drift_without_syncing
printf 'ok\n'
