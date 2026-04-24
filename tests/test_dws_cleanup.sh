#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-cleanup.sh"

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

cleanup_fixture() {
  if [ -n "${ORIG_PATH:-}" ]; then
    export PATH="${ORIG_PATH}"
  fi

  unset DWS_TMPDIR DWS_REPO_ROOT DWS_PROJECTS_ROOT DWS_PIP_CACHE_DIR DWS_APT_CACHE_DIR DWS_CLEANUP_STAMP_PATH

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "/tmp/dws-cleanup-test.XXXXXX")
  ORIG_PATH="${PATH}"

  export DWS_TMPDIR="${FIXTURE_ROOT}/tmp"
  export DWS_REPO_ROOT="${FIXTURE_ROOT}/repo"
  export DWS_PROJECTS_ROOT="${FIXTURE_ROOT}/projects"
  export DWS_PIP_CACHE_DIR="${FIXTURE_ROOT}/pip-cache"
  export DWS_APT_CACHE_DIR="${FIXTURE_ROOT}/apt-cache"
  export DWS_CLEANUP_STAMP_PATH="${FIXTURE_ROOT}/cleanup-stamp"

  FAKE_BIN="${FIXTURE_ROOT}/fake-bin"
  export PATH="${FAKE_BIN}:${PATH}"

  mkdir -p \
    "${DWS_TMPDIR}" \
    "${DWS_REPO_ROOT}" \
    "${DWS_PROJECTS_ROOT}" \
    "${DWS_PIP_CACHE_DIR}" \
    "${DWS_APT_CACHE_DIR}" \
    "${FAKE_BIN}"

  git -C "${DWS_REPO_ROOT}" init -q
  git -C "${DWS_REPO_ROOT}" config user.name 'Test User'
  git -C "${DWS_REPO_ROOT}" config user.email 'test@example.com'
  printf 'tracked\n' >"${DWS_REPO_ROOT}/README.md"
  git -C "${DWS_REPO_ROOT}" add README.md
  git -C "${DWS_REPO_ROOT}" commit -q -m 'initial commit'

  printf 'recent log\n' >"${DWS_TMPDIR}/dws-health.log"
  touch -d '4 days ago' "${DWS_TMPDIR}/dws-health.log"

  printf 'old archive\n' | gzip -c >"${DWS_TMPDIR}/dws-history.log.gz"
  touch -d '8 days ago' "${DWS_TMPDIR}/dws-history.log.gz"

  printf 'temp\n' >"${DWS_TMPDIR}/dws-backup-manifest.txt"
  touch -d '5 days ago' "${DWS_TMPDIR}/dws-backup-manifest.txt"

  printf 'cache\n' >"${DWS_PIP_CACHE_DIR}/wheel.whl"
  printf 'deb\n' >"${DWS_APT_CACHE_DIR}/pkg.deb"

  cat >"${FAKE_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${FAKE_BIN}/tmux"
}

test_cleanup_dry_run_reports_actions_without_mutating() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  output=$("${SCRIPT}" --dry-run 2>&1)

  assert_contains "${output}" "would compress log"
  assert_contains "${output}" "would remove log"
  assert_contains "${output}" "would remove temp"
  assert_contains "${output}" "would clean pip-cache"
  assert_contains "${output}" "would clean apt-cache"
  assert_contains "${output}" "Summary (dry-run)"

  [ -f "${DWS_TMPDIR}/dws-health.log" ] || fail "expected dry-run to keep source log"
  [ -f "${DWS_TMPDIR}/dws-history.log.gz" ] || fail "expected dry-run to keep archived log"
  [ -f "${DWS_TMPDIR}/dws-backup-manifest.txt" ] || fail "expected dry-run to keep temp file"
  [ -f "${DWS_PIP_CACHE_DIR}/wheel.whl" ] || fail "expected dry-run to keep pip cache"
  [ -f "${DWS_APT_CACHE_DIR}/pkg.deb" ] || fail "expected dry-run to keep apt cache"
  [ ! -e "${DWS_CLEANUP_STAMP_PATH}" ] || fail "expected dry-run not to write cleanup stamp"

  cleanup_fixture
  trap - EXIT
}

test_cleanup_dry_run_reports_actions_without_mutating
printf 'PASS: %s\n' "$(basename "$0")"
