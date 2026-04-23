#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dws-env.sh"

[ -n "${AZURE_OPENAI_API_KEY:-}" ] || {
  [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"
}

PASS_COUNT=0
FAIL_COUNT=0

DEFAULT_CODEX_API_BASE_URL='https://moses-8586-resource.cognitiveservices.azure.com/openai'
DEFAULT_CODEX_API_VERSION='2025-04-01-preview'
CODEX_PROVIDER_CONFIG="${DWS_CONNECT_PROVIDER_CONFIG:-${REPO_ROOT}/config/codex-profiles/00-provider-azure-foundry.toml}"
PING_TIMEOUT_SECONDS="${DWS_CONNECT_PING_TIMEOUT_SECONDS:-3}"
SSH_TIMEOUT_SECONDS="${DWS_CONNECT_SSH_TIMEOUT_SECONDS:-5}"
CURL_TIMEOUT_SECONDS="${DWS_CONNECT_CURL_TIMEOUT_SECONDS:-5}"

supports_color() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

paint() {
  if supports_color; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '%s %s\n' "$(paint 32 PASS)" "$*"
}

fail_check() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '%s %s\n' "$(paint 31 FAIL)" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
usage: dws-connect-test.sh [--help]

VM-side connectivity checks for:
  - Tailscale peer reachability (Mac, iPhone, gateway)
  - VM -> Mac SSH connectivity
  - Azure Foundry / Codex API reachability
  - DNS resolution

Environment overrides:
  DWS_CONNECT_SSH_TARGET
  DWS_CONNECT_CODEX_API_URL
  DWS_CONNECT_DNS_HOSTS
  DWS_CONNECT_PING_TIMEOUT_SECONDS
  DWS_CONNECT_SSH_TIMEOUT_SECONDS
  DWS_CONNECT_CURL_TIMEOUT_SECONDS
EOF
}

provider_base_url() {
  [ -f "$CODEX_PROVIDER_CONFIG" ] || return 1
  awk -F'"' '/^base_url = / { print $2; exit }' "$CODEX_PROVIDER_CONFIG"
}

provider_api_version() {
  [ -f "$CODEX_PROVIDER_CONFIG" ] || return 1
  sed -n 's/^query_params = { api-version = "\(.*\)" }/\1/p' "$CODEX_PROVIDER_CONFIG" | sed -n '1p'
}

host_from_url() {
  local url="${1:-}" host

  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%\?*}"
  host="${host%%:*}"
  printf '%s\n' "$host"
}

resolve_host() {
  local host="${1:-}" resolved=''

  if have getent; then
    resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 { print $1; exit }' || true)
    [ -n "$resolved" ] || resolved=$(getent hosts "$host" 2>/dev/null | awk 'NR == 1 { print $1; exit }' || true)
  fi

  if [ -z "$resolved" ] && have host; then
    resolved=$(host "$host" 2>/dev/null | awk '/ has address / { print $4; exit }' || true)
  fi

  if [ -z "$resolved" ] && have dig; then
    resolved=$(dig +short "$host" 2>/dev/null | sed -n '1p' || true)
  fi

  if [ -z "$resolved" ] && have nslookup; then
    resolved=$(nslookup "$host" 2>/dev/null | awk '/^Address: / { print $2 }' | sed -n '1p' || true)
  fi

  [ -n "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

api_status_code() {
  local url="$1" code
  local curl_args=(
    -sS
    -o /dev/null
    -w '%{http_code}'
    --max-time "$CURL_TIMEOUT_SECONDS"
  )

  if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    curl_args+=(-H "api-key: ${AZURE_OPENAI_API_KEY}")
  fi

  code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || return 1
  printf '%s\n' "$code"
}

http_reachable() {
  case "${1:-}" in
    2??|401|403|405|408|409|429) return 0 ;;
    *) return 1 ;;
  esac
}

run_with_timeout() {
  local seconds="$1"
  shift

  if have timeout; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

check_peer_ping() {
  local label="$1" ip="$2" out latency

  if ! have tailscale; then
    fail_check "ping ${label} (${ip}): tailscale missing"
    return 0
  fi

  if ! out=$(run_with_timeout "$PING_TIMEOUT_SECONDS" tailscale ping -c 1 "$ip" 2>/dev/null | sed -n '1p'); then
    fail_check "ping ${label} (${ip}): unreachable"
    return 0
  fi

  latency=$(printf '%s\n' "$out" | sed -n 's/.* in \([^ ]*\)$/\1/p')
  if [ -n "$latency" ]; then
    pass "ping ${label} (${ip}): ${latency}"
  else
    pass "ping ${label} (${ip})"
  fi
}

check_ssh_reverse() {
  local target="$1" out

  if ! have ssh; then
    fail_check "ssh reverse (${target}): ssh missing"
    return 0
  fi

  if out=$(ssh \
      -o BatchMode=yes \
      -o ConnectTimeout="$SSH_TIMEOUT_SECONDS" \
      -o StrictHostKeyChecking=accept-new \
      -o LogLevel=ERROR \
      "$target" "printf vm-ssh-ok" 2>/dev/null); then
    case "$out" in
      *vm-ssh-ok*) pass "ssh reverse (${target})" ;;
      *) fail_check "ssh reverse (${target}): unexpected output" ;;
    esac
  else
    fail_check "ssh reverse (${target}): unreachable"
  fi
}

check_codex_api() {
  local url="$1" code

  if ! have curl; then
    fail_check "codex api (${url}): curl missing"
    return 0
  fi

  if ! code=$(api_status_code "$url"); then
    fail_check "codex api (${url}): connection failed"
    return 0
  fi

  if http_reachable "$code"; then
    pass "codex api (${url}): HTTP ${code}"
  else
    fail_check "codex api (${url}): HTTP ${code}"
  fi
}

check_dns_hosts() {
  local host resolved

  if [ $# -eq 0 ]; then
    fail_check 'dns: no host configured'
    return 0
  fi

  for host in "$@"; do
    if resolved=$(resolve_host "$host"); then
      pass "dns ${host}: ${resolved}"
    else
      fail_check "dns ${host}: unresolved"
    fi
  done
}

main() {
  local configured_base_url configured_api_version
  local codex_api_base_url codex_api_version codex_api_url codex_api_host
  local ssh_target dns_hosts
  local dns_targets=()
  local host

  case "${1:-}" in
    '' ) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac

  configured_base_url=$(provider_base_url || true)
  configured_api_version=$(provider_api_version || true)

  codex_api_base_url="${DWS_CONNECT_CODEX_API_BASE_URL:-${configured_base_url:-$DEFAULT_CODEX_API_BASE_URL}}"
  codex_api_version="${DWS_CONNECT_CODEX_API_VERSION:-${configured_api_version:-$DEFAULT_CODEX_API_VERSION}}"
  codex_api_url="${DWS_CONNECT_CODEX_API_URL:-${codex_api_base_url%/}/models?api-version=${codex_api_version}}"
  codex_api_host=$(host_from_url "$codex_api_url")
  ssh_target="${DWS_CONNECT_SSH_TARGET:-${MAC_SSH_HOST:-mosestut@100.78.207.22}}"
  dns_hosts="${DWS_CONNECT_DNS_HOSTS:-${codex_api_host}}"

  for host in $dns_hosts; do
    [ -n "$host" ] || continue
    dns_targets+=("$host")
  done

  check_peer_ping mac 100.78.207.22
  check_peer_ping iphone 100.88.249.22
  check_peer_ping gateway 100.126.194.98
  check_ssh_reverse "$ssh_target"
  check_codex_api "$codex_api_url"
  check_dns_hosts "${dns_targets[@]}"

  printf 'Summary: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
