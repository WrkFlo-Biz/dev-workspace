#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

is_standalone_bin_program() {
  case "${1:-}" in
    dws-boot-verify.sh|dws-systemd-user-setup.sh) return 0 ;;
    *) return 1 ;;
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

cleanup_fixture() {
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-e2e-smoke-test.XXXXXX")
  FAKE_BIN="${FIXTURE_ROOT}/bin"
  export HOME="${FIXTURE_ROOT}/home"
  export PATH="${FAKE_BIN}:${ORIG_PATH}"

  mkdir -p "${FAKE_BIN}" "${HOME}/projects"
  ln -s "${REPO_ROOT}" "${HOME}/projects/dev-workspace"

  write_fake_command systemctl '
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ]; then
  case "${3:-}" in
    dws-task-monitor)
      printf "active\n"
      exit 0
      ;;
    dws-sessions-init)
      printf "inactive\n"
      exit 3
      ;;
  esac
fi
exit 1
'

  write_fake_command tmux '
if [ "${1:-}" = "list-sessions" ]; then
  printf "dws-a\n"
  exit 0
fi
exit 1
'

  write_fake_command tailscale '
case "${1:-} ${2:-}" in
  "status ")
    printf "100.64.0.10 dev-workspace-vm online\n"
    exit 0
    ;;
  "ip -4")
    printf "100.64.0.10\n"
    exit 0
    ;;
esac
exit 1
'

  write_fake_command crontab '
if [ "${1:-}" = "-l" ]; then
  printf "*/15 * * * * echo dws-health-check\n"
  exit 0
fi
exit 1
'

  write_fake_command df '
case "$*" in
  "/ --output=pcent"|"--output=pcent /")
    cat <<'"'"'EOF'"'"'
Use%
41%
EOF
    ;;
  *)
    cat <<'"'"'EOF'"'"'
Filesystem     1K-blocks   Used Available Use% Mounted on
/dev/root        1000000 410000    590000  41% /
EOF
    ;;
esac
'
}

assert_valid_json_file() {
  local path="$1"

  python3 - "$path" <<'PY'
from __future__ import annotations

import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
}

assert_valid_json_text() {
  local text="${1:-}"

  python3 - <<'PY' <<<"${text}"
from __future__ import annotations

import json
import sys

json.load(sys.stdin)
PY
}

test_tracked_scripts_are_executable_and_parse() {
  local script

  while IFS= read -r script; do
    [ -n "${script}" ] || continue
    [ -x "${REPO_ROOT}/${script}" ] || fail "tracked script is not executable: ${script}"
    bash -n "${REPO_ROOT}/${script}" || fail "bash syntax check failed: ${script}"
  done < <(git -C "${REPO_ROOT}" ls-files 'scripts/*.sh' | sort)
}

test_tracked_bin_wrappers_exec_matching_scripts() {
  local wrapper name expected exec_lines

  while IFS= read -r wrapper; do
    [ -n "${wrapper}" ] || continue
    name=$(basename "${wrapper}")

    [ -x "${REPO_ROOT}/${wrapper}" ] || fail "tracked wrapper is not executable: ${wrapper}"
    bash -n "${REPO_ROOT}/${wrapper}" || fail "bash syntax check failed: ${wrapper}"

    if is_standalone_bin_program "${name}"; then
      continue
    fi

    expected="${REPO_ROOT}/scripts/${name}"
    [ -x "${expected}" ] || fail "missing executable counterpart for ${wrapper}: ${expected}"

    exec_lines=$(awk '/^exec / { print }' "${REPO_ROOT}/${wrapper}")
    [ -n "${exec_lines}" ] || fail "wrapper does not exec a target: ${wrapper}"

    printf '%s\n' "${exec_lines}" | grep -F "../scripts/${name}" >/dev/null 2>&1 || \
      fail "wrapper does not exec scripts/${name}: ${wrapper}"
  done < <(git -C "${REPO_ROOT}" ls-files 'bin/*.sh' | sort)
}

test_repo_state_files_exist_and_validate() {
  [ -s "${REPO_ROOT}/.state/orchestrator-context.md" ] || fail "expected non-empty orchestrator context"
  [ -f "${REPO_ROOT}/.state/task-queue.json" ] || fail "missing task queue file"
  assert_valid_json_file "${REPO_ROOT}/.state/task-queue.json"
}

test_safe_mode_status_runs_without_live_services() {
  local output

  output=$(bash "${REPO_ROOT}/bin/dws-safe-mode.sh" status 2>&1)
  assert_contains "${output}" "safe-mode:"
}

test_summary_runs_without_live_services() {
  local output

  output=$(bash "${REPO_ROOT}/bin/dws-summary.sh" --json 2>&1)
  assert_valid_json_text "${output}"
}

make_fixture
trap cleanup_fixture EXIT

test_tracked_scripts_are_executable_and_parse
test_tracked_bin_wrappers_exec_matching_scripts
test_repo_state_files_exist_and_validate
test_safe_mode_status_runs_without_live_services
test_summary_runs_without_live_services

printf 'PASS: %s\n' "$(basename "$0")"
