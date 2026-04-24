#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/scripts/dws-sessions-init.sh"
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-sessions-init.XXXXXX")
FAKE_BIN=""

cleanup() {
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  unset DWS_PROJECTS_ROOT DWS_FOUNDRY_ENV_PATH
  rm -rf -- "${FIXTURE_ROOT}"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf 'SKIP: %s\n' "$*"
  exit 0
}

assert_contains() {
  local haystack="${1:-}" needle="${2:-}"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing output: $needle"
}

assert_not_contains() {
  local haystack="${1:-}" needle="${2:-}"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    fail "unexpected output: $needle"
  fi
}

write_fake_command() {
  local name="${1:-}" body="${2:-}" path
  path="${FAKE_BIN}/${name}"

  cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${path}"
}

trap cleanup EXIT

[ -f "$SCRIPT" ] || fail "missing init script: $SCRIPT"

export HOME="${FIXTURE_ROOT}/home"
export DWS_PROJECTS_ROOT="${HOME}/projects"
export DWS_FOUNDRY_ENV_PATH="${HOME}/.config/wrkflo/foundry.env"
FAKE_BIN="${FIXTURE_ROOT}/bin"
export PATH="${FAKE_BIN}:${ORIG_PATH}"

mkdir -p \
  "${FAKE_BIN}" \
  "${HOME}/projects/dev-workspace" \
  "${HOME}/projects/wrkflo-orchestrator" \
  "${HOME}/projects/global-sentinel" \
  "$(dirname "$DWS_FOUNDRY_ENV_PATH")"

printf 'AZURE_OPENAI_API_KEY=test-key\n' > "$DWS_FOUNDRY_ENV_PATH"

write_fake_command systemctl '
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show" ] && [ "${3:-}" = "default.target" ]; then
  exit 0
fi

if [ "${1:-}" = "--user" ] && [ "${2:-}" = "cat" ] && [ "${3:-}" = "wrkflo-orchestrator-api.service" ]; then
  exit 0
fi

if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ] && [ "${3:-}" = "--quiet" ] && [ "${4:-}" = "wrkflo-orchestrator-api.service" ]; then
  exit 3
fi

if [ "${1:-}" = "--user" ] && [ "${2:-}" = "start" ] && [ "${3:-}" = "wrkflo-orchestrator-api.service" ]; then
  printf "unexpected orchestrator start\n" >&2
  exit 99
fi

exit 1
'

# Run the init script
output=$(bash "$SCRIPT" 2>&1)

# Verify foundry env detection
assert_contains "$output" "foundry env present"

# Verify project discovery
assert_contains "$output" "project: dev-workspace"
assert_contains "$output" "project: wrkflo-orchestrator"
assert_contains "$output" "project: global-sentinel"

# Verify no persistent sessions are created
assert_not_contains "$output" "created dws-a"
assert_not_contains "$output" "created worker-"
assert_not_contains "$output" "created orchestrator"

# Verify orchestrator remains on-demand
assert_contains "$output" "orchestrator API: installed but left stopped (on-demand)"
assert_not_contains "$output" "orchestrator API: started"
assert_not_contains "$output" "unexpected orchestrator start"

# Verify on-demand model message
assert_contains "$output" "on-demand model"

printf 'PASS: dws sessions init (on-demand model)\n'
