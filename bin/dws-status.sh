#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${BASE_DIR}/.." && pwd)
STATUS_URL="${DWS_ORCHESTRATOR_HEALTH_URL:-http://127.0.0.1:8100/v1/workspace/health}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dws-env.sh"

usage() {
  cat <<'EOF'
usage: dws-status.sh [--json|--motd|--help]

Query the local orchestrator workspace health endpoint and render either raw
JSON, a one-line MOTD summary, or a full operator status page.
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

payload() {
  local body
  need_cmd curl || { printf 'missing curl\n' >&2; return 1; }
  need_cmd jq || { printf 'missing jq\n' >&2; return 1; }
  body=$(curl -fsS --max-time 2 "$STATUS_URL") || {
    printf 'orchestrator health unavailable: %s\n' "$STATUS_URL" >&2
    return 1
  }
  jq -e . >/dev/null 2>&1 <<<"$body" || {
    printf 'orchestrator health returned invalid json\n' >&2
    return 1
  }
  printf '%s\n' "$body"
}

render_motd() {
  local body="$1" hostname sessions projects dirty tailscale_ip
  hostname=$(jq -r '.vm.hostname // "-"' <<<"$body")
  sessions=$(jq -r '(.sessions // []) | length' <<<"$body")
  projects=$(jq -r '(.projects // []) | length' <<<"$body")
  dirty=$(jq -r '[.projects[]? | select(.dirty)] | length' <<<"$body")
  tailscale_ip=$(jq -r '.tailscale.ip // ""' <<<"$body")
  printf '  orchestrator: %s  host=%s  sessions=%s  projects=%s  dirty=%s' "$(green "ok")" "$hostname" "$sessions" "$projects" "$dirty"
  if [ -n "$tailscale_ip" ]; then
    printf '  tailnet=%s' "$tailscale_ip"
  fi
  printf '\n'
}

render_full() {
  local body="$1"
  local count uptime disk_percent memory_percent hostname tailscale_ip
  local tailscale_connected foundry_loaded project_count

  echo "  $(green "orchestrator health API")"
  printf '    source: %s\n' "$STATUS_URL"
  echo

  bold "  active sessions"; echo
  count=$(jq -r '(.sessions // []) | length' <<<"$body")
  if [ "$count" -gt 0 ]; then
    jq -r '.sessions[]?' <<<"$body" | sed 's/^/    /'
  else
    dim "    (none)"; echo
  fi
  echo

  bold "  projects"; echo
  project_count=$(jq -r '(.projects // []) | length' <<<"$body")
  if [ "$project_count" -gt 0 ]; then
    while IFS=$'\t' read -r name branch dirty; do
      [ -n "$name" ] || continue
      if [ "$dirty" = "true" ]; then
        printf '    %-28s %s %s\n' "$name" "${branch:--}" "$(yellow "*dirty")"
      else
        printf '    %-28s %s\n' "$name" "${branch:--}"
      fi
    done < <(jq -r '.projects[]? | [.name, (.branch // "-"), (if .dirty then "true" else "false" end)] | @tsv' <<<"$body")
  else
    dim "    (none)"; echo
  fi
  echo

  hostname=$(jq -r '.vm.hostname // "-"' <<<"$body")
  uptime=$(jq -r '.vm.uptime // "-"' <<<"$body")
  disk_percent=$(jq -r '.vm.disk_percent // 0' <<<"$body")
  memory_percent=$(jq -r '.vm.memory_percent // 0' <<<"$body")
  foundry_loaded=$(jq -r '.foundry_key.loaded // false' <<<"$body")
  tailscale_connected=$(jq -r '.tailscale.connected // false' <<<"$body")
  tailscale_ip=$(jq -r '.tailscale.ip // ""' <<<"$body")

  bold "  system"; echo
  printf '    host:   %s\n' "$hostname"
  printf '    uptime: %s\n' "$uptime"
  printf '    disk:   %s%% used\n' "$disk_percent"
  printf '    mem:    %s%% used\n' "$memory_percent"
  if [ "$foundry_loaded" = "true" ]; then
    printf '    key:    %s\n' "$(green "ok")"
  else
    printf '    key:    %s\n' "$(red "missing")"
  fi
  echo

  bold "  tailnet"; echo
  if [ "$tailscale_connected" = "true" ]; then
    if [ -n "$tailscale_ip" ]; then
      printf '    connected: %s (%s)\n' "$(green "yes")" "$tailscale_ip"
    else
      printf '    connected: %s\n' "$(green "yes")"
    fi
  else
    printf '    connected: %s\n' "$(red "no")"
  fi
}

main() {
  local mode body
  mode="${1:-}"
  case "$mode" in
    ''|--json|--motd) ;;
    -h|--help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  body=$(payload) || {
    case "$mode" in
      --json)
        printf '{"error":"orchestrator health unavailable","url":"%s"}\n' "$STATUS_URL"
        ;;
      --motd)
        printf '  orchestrator: %s  source=%s\n' "$(red "unavailable")" "$STATUS_URL"
        ;;
      *)
        red "orchestrator health unavailable"; echo
        printf '  source: %s\n' "$STATUS_URL"
        ;;
    esac
    return 1
  }

  case "$mode" in
    --json) printf '%s\n' "$body" ;;
    --motd) render_motd "$body" ;;
    *) render_full "$body" ;;
  esac
}

main "$@"
