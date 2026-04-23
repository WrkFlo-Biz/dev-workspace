#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dws-env.sh"

PING_TIMEOUT_SECONDS="${DWS_TAILSCALE_PING_TIMEOUT_SECONDS:-5}"
MAC_TAILSCALE_TARGET_DEFAULT="${DWS_MAC_TAILSCALE_TARGET:-}"
PHONE_TAILSCALE_TARGET="${DWS_PHONE_TAILSCALE_TARGET:-100.88.249.22}"
GATEWAY_TAILSCALE_TARGET="${DWS_GATEWAY_TAILSCALE_TARGET:-100.126.194.98}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
DIRECT_COUNT=0
DERP_COUNT=0
UNREACHABLE_COUNT=0

STATUS_JSON=''
STATUS_JSON_OK=0
VERSION_JSON=''
VERSION_JSON_OK=0

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

bold() {
  paint '1' "$1"
}

cyan() {
  paint '1;36' "$1"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  %s %s\n' "$(paint 32 PASS)" "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '  %s %s\n' "$(paint 33 WARN)" "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  %s %s\n' "$(paint 31 FAIL)" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n%s\n' "$(cyan "$1")"
}

usage() {
  cat <<'EOF'
usage: dws-tailscale-diag.sh [--help]

Render a Tailscale diagnostic report covering:
  - current tailscale status
  - ping/latency for known peers
  - direct vs DERP transport
  - installed tailscale version
  - update availability

Environment overrides:
  DWS_MAC_TAILSCALE_TARGET
  DWS_PHONE_TAILSCALE_TARGET
  DWS_GATEWAY_TAILSCALE_TARGET
  DWS_TAILSCALE_KNOWN_PEERS
  DWS_TAILSCALE_PING_TIMEOUT_SECONDS
EOF
}

host_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown'
}

timestamp_utc() {
  date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %Z'
}

host_from_url() {
  local url="${1:-}" host

  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%\?*}"
  host="${host%%:*}"
  printf '%s\n' "$host"
}

trim_trailing_dot() {
  printf '%s\n' "${1:-}" | sed 's/\.$//'
}

first_line() {
  sed -n '1p'
}

normalize_text() {
  sed '/^$/d' | paste -sd '; ' -
}

shorten() {
  local text="${1:-}"
  local max_chars="${2:-180}"

  awk -v max="$max_chars" '
    {
      if (length($0) <= max) {
        print $0
      } else {
        print substr($0, 1, max - 3) "..."
      }
    }
  ' <<<"$text"
}

summarize_text() {
  local text="${1:-}"
  local max_chars="${2:-180}"
  local normalized

  normalized=$(printf '%s\n' "$text" | normalize_text)
  shorten "$normalized" "$max_chars"
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

json_ok() {
  have jq && jq -e . >/dev/null 2>&1 <<<"${1:-}"
}

known_peers_string() {
  local mac_target

  mac_target="${MAC_TAILSCALE_TARGET_DEFAULT:-$(host_from_url "${MAC_GUI_URL:-http://100.78.207.22:9223}")}"
  printf '%s\n' "${DWS_TAILSCALE_KNOWN_PEERS:-mac=${mac_target} iphone=${PHONE_TAILSCALE_TARGET} gateway=${GATEWAY_TAILSCALE_TARGET}}"
}

collect_status_json() {
  local out

  out=$(tailscale status --json 2>&1 || true)
  if json_ok "$out"; then
    STATUS_JSON="$out"
    STATUS_JSON_OK=1
  else
    STATUS_JSON=''
    STATUS_JSON_OK=0
  fi
}

collect_version_json() {
  local out

  out=$(tailscale version --json 2>&1 || true)
  if json_ok "$out"; then
    VERSION_JSON="$out"
    VERSION_JSON_OK=1
  else
    VERSION_JSON=''
    VERSION_JSON_OK=0
  fi
}

json_self_ip() {
  [ "$STATUS_JSON_OK" -eq 1 ] || return 1
  jq -r '
    (((.Self.TailscaleIPs // []) + (.TailscaleIPs // []))
      | map(select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")))
      | .[0]) // ""
  ' <<<"$STATUS_JSON"
}

json_backend_state() {
  [ "$STATUS_JSON_OK" -eq 1 ] || return 1
  jq -r '.BackendState // ""' <<<"$STATUS_JSON"
}

json_tailnet_name() {
  [ "$STATUS_JSON_OK" -eq 1 ] || return 1
  jq -r '.CurrentTailnet.Name // .MagicDNSSuffix // ""' <<<"$STATUS_JSON"
}

json_magicdns_state() {
  [ "$STATUS_JSON_OK" -eq 1 ] || return 1
  jq -r '
    if .CurrentTailnet.MagicDNSEnabled == true then
      "enabled"
    elif .CurrentTailnet.MagicDNSEnabled == false then
      "disabled"
    else
      "unknown"
    end
  ' <<<"$STATUS_JSON"
}

json_health_lines() {
  [ "$STATUS_JSON_OK" -eq 1 ] || return 1
  jq -r '.Health[]?' <<<"$STATUS_JSON"
}

peer_metadata_tsv() {
  local target="$1"

  [ "$STATUS_JSON_OK" -eq 1 ] || return 1
  jq -r --arg target "$target" '
    (.Peer // {}) | to_entries[]?.value |
    select(
      (((.TailscaleIPs // []) | index($target)) != null)
      or ((.HostName // "") == $target)
      or (((.DNSName // "") | sub("\\.$"; "")) == $target)
    ) |
    [
      (.HostName // ""),
      ((.DNSName // "") | sub("\\.$"; "")),
      (.OS // ""),
      (.Online // false | tostring),
      (.Active // false | tostring),
      (.Relay // ""),
      (.CurAddr // ""),
      (((.TailscaleIPs // []) | map(select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))) | .[0]) // "")
    ] | @tsv
  ' <<<"$STATUS_JSON" | sed -n '1p'
}

peer_display_name() {
  local host_name_value="$1" dns_name_value="$2" ping_name="$3"

  if [ -n "$host_name_value" ]; then
    printf '%s\n' "$host_name_value"
  elif [ -n "$dns_name_value" ]; then
    printf '%s\n' "$dns_name_value"
  elif [ -n "$ping_name" ]; then
    printf '%s\n' "$ping_name"
  else
    printf 'unknown-peer\n'
  fi
}

ping_pong_line() {
  sed -n '/^pong from /{p;q;}'
}

ping_name() {
  sed -n 's/^pong from \([^ ]*\) (.*/\1/p'
}

ping_latency() {
  sed -n 's/.* in \([^ ]*\)$/\1/p'
}

ping_transport_kind() {
  local line="${1:-}"

  case "$line" in
    *" via DERP("*")"*) printf 'derp\n' ;;
    *" via "*) printf 'direct\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

ping_transport_detail() {
  local line="${1:-}"

  case "$line" in
    *" via DERP("*")"*)
      sed -n 's/.* via DERP(\([^)]*\)).*/\1/p' <<<"$line"
      ;;
    *" via "*)
      sed -n 's/.* via \([^ ]*\) in .*/\1/p' <<<"$line"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

print_header() {
  printf '%s\n' "$(bold 'Tailscale Diagnostic Report')"
  printf '  host: %s\n' "$(host_name)"
  printf '  time: %s\n' "$(timestamp_utc)"
  printf '  peers: %s\n' "$(known_peers_string)"
}

check_tailscale_status() {
  local backend_state self_ip tailnet_name magicdns_state health_lines

  section "Status"

  if ! have tailscale; then
    fail "tailscale CLI missing"
    return
  fi

  collect_status_json
  if [ "$STATUS_JSON_OK" -eq 1 ]; then
    backend_state=$(json_backend_state || true)
    self_ip=$(json_self_ip || true)
    tailnet_name=$(json_tailnet_name || true)
    magicdns_state=$(json_magicdns_state || true)

    if [ "$backend_state" = "Running" ]; then
      pass "tailscale status ${backend_state} (${self_ip:-no-ip} on ${tailnet_name:-unknown-tailnet}; MagicDNS ${magicdns_state:-unknown})"
    else
      fail "tailscale status ${backend_state:-unknown}"
    fi

    health_lines=$(json_health_lines || true)
    if [ -n "$health_lines" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        warn "tailscale health $(shorten "$line" 180)"
      done <<<"$health_lines"
    else
      pass "tailscale health clear"
    fi
    return
  fi

  if tailscale status >/dev/null 2>&1; then
    self_ip=$(tailscale ip -4 2>/dev/null | sed -n '1p')
    pass "tailscale status connected (${self_ip:-no-ip})"
  else
    fail "tailscale status unavailable"
  fi
}

check_peer_ping() {
  local label="$1" target="$2"
  local metadata host_name_value dns_name_value os_name online active relay cur_addr peer_ip
  local ping_output line ping_name_value display_name latency transport_kind transport_detail route_text base_name

  metadata=$(peer_metadata_tsv "$target" || true)
  host_name_value=''
  dns_name_value=''
  os_name=''
  online=''
  active=''
  relay=''
  cur_addr=''
  peer_ip=''

  if [ -n "$metadata" ]; then
    IFS=$'\t' read -r host_name_value dns_name_value os_name online active relay cur_addr peer_ip <<<"$metadata"
  fi

  ping_output=$(run_with_timeout "$PING_TIMEOUT_SECONDS" tailscale ping -c 1 "$target" 2>&1 || true)
  line=$(printf '%s\n' "$ping_output" | ping_pong_line || true)

  if [ -z "$line" ]; then
    local failure_detail

    UNREACHABLE_COUNT=$((UNREACHABLE_COUNT + 1))
    failure_detail=$(summarize_text "$ping_output" 180)
    if [ -n "$failure_detail" ]; then
      fail "${label}: ${target} unreachable (${failure_detail})"
    else
      fail "${label}: ${target} unreachable"
    fi
    return
  fi

  ping_name_value=$(printf '%s\n' "$line" | ping_name || true)
  display_name=$(peer_display_name "$host_name_value" "$(trim_trailing_dot "$dns_name_value")" "$ping_name_value")
  latency=$(printf '%s\n' "$line" | ping_latency || true)
  transport_kind=$(ping_transport_kind "$line")
  transport_detail=$(ping_transport_detail "$line")

  base_name="${label}: ${display_name} (${target})"
  if [ -n "$peer_ip" ] && [ "$peer_ip" != "$target" ]; then
    base_name="${label}: ${display_name} (${peer_ip})"
  fi

  case "$transport_kind" in
    direct)
      DIRECT_COUNT=$((DIRECT_COUNT + 1))
      route_text="direct ${transport_detail:-unknown-route}"
      ;;
    derp)
      DERP_COUNT=$((DERP_COUNT + 1))
      route_text="DERP ${transport_detail:-unknown-region}"
      ;;
    *)
      route_text="transport unknown"
      ;;
  esac

  if [ -n "$latency" ]; then
    if [ -n "$os_name" ]; then
      pass "${base_name} ${os_name} ${route_text} ${latency}"
    else
      pass "${base_name} ${route_text} ${latency}"
    fi
  else
    if [ -n "$os_name" ]; then
      pass "${base_name} ${os_name} ${route_text}"
    else
      pass "${base_name} ${route_text}"
    fi
  fi
}

check_known_peers() {
  local peers spec label target

  section "Peers"

  peers=$(known_peers_string)
  for spec in $peers; do
    label="${spec%%=*}"
    target="${spec#*=}"
    [ -n "$label" ] || continue
    [ -n "$target" ] || {
      warn "peer ${label} has no target configured"
      continue
    }
    check_peer_ping "$label" "$target"
  done
}

check_version() {
  local short_version long_version plain_version

  section "Version"

  collect_version_json
  if [ "$VERSION_JSON_OK" -eq 1 ]; then
    short_version=$(jq -r '.short // .majorMinorPatch // ""' <<<"$VERSION_JSON")
    long_version=$(jq -r '.long // ""' <<<"$VERSION_JSON")
    if [ -n "$short_version" ] && [ -n "$long_version" ]; then
      pass "tailscale version ${short_version} (${long_version})"
    elif [ -n "$short_version" ]; then
      pass "tailscale version ${short_version}"
    else
      warn "tailscale version json did not include a version string"
    fi
    return
  fi

  plain_version=$(tailscale version 2>&1 | first_line || true)
  if [ -n "$plain_version" ]; then
    pass "tailscale version ${plain_version}"
  else
    fail "tailscale version unavailable"
  fi
}

check_update_availability() {
  local update_output normalized

  update_output=$(tailscale update --dry-run 2>&1 || true)
  case "$update_output" in
    *'must be root'*|*'use sudo'*)
      if have sudo; then
        update_output=$(sudo -n tailscale update --dry-run 2>&1 || true)
      fi
      ;;
  esac

  normalized=$(summarize_text "$update_output" 180)
  if [ -z "$normalized" ]; then
    warn "updates unavailable"
    return
  fi

  case "$normalized" in
    *'no update needed'*|*'already running'*)
      pass "updates ${normalized}"
      ;;
    *'would update'*|*'would install'*|*'update available'*|*'new version available'*|*'latest version '*)
      warn "updates ${normalized}"
      ;;
    *'password is required'*|*'permission denied'*|*'not permitted'*)
      warn "updates unavailable (${normalized})"
      ;;
    *)
      warn "updates ${normalized}"
      ;;
  esac
}

render_summary() {
  local overall

  if [ "$FAIL_COUNT" -gt 0 ]; then
    overall=$(paint 31 FAIL)
  elif [ "$WARN_COUNT" -gt 0 ]; then
    overall=$(paint 33 WARN)
  else
    overall=$(paint 32 PASS)
  fi

  printf '\n%s\n' "$(bold 'Summary')"
  printf '  overall: %s\n' "$overall"
  printf '  pass: %s\n' "$PASS_COUNT"
  printf '  warn: %s\n' "$WARN_COUNT"
  printf '  fail: %s\n' "$FAIL_COUNT"
  printf '  direct peers: %s\n' "$DIRECT_COUNT"
  printf '  derp peers: %s\n' "$DERP_COUNT"
  printf '  unreachable peers: %s\n' "$UNREACHABLE_COUNT"
}

main() {
  case "${1:-}" in
    '') ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  print_header

  if ! have tailscale; then
    section "Status"
    fail "tailscale CLI missing"
    render_summary
    exit 1
  fi

  check_tailscale_status
  check_known_peers
  check_version
  check_update_availability
  render_summary

  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
