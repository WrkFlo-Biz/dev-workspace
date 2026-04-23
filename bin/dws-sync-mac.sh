#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

# shellcheck source=../scripts/dws-env.sh
. "${REPO_ROOT}/scripts/dws-env.sh"

SSH_RSH='ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new'
MAC_SSH_HOST="${MAC_SSH_HOST:-mosestut@100.78.207.22}"
MAC_GUI_URL="${MAC_GUI_URL:-http://100.78.207.22:9223}"
MAC_CDP_URL="${MAC_CDP_URL:-http://100.78.207.22:9222}"
PUSH_PATHS=(
  "bin"
  "scripts"
  "mac-setup/chrome-cdp.sh"
  "mac-setup/mac-bridges.sh"
)
MAC_LAUNCH_AGENTS=(
  "com.wrkflo.chrome-cdp.plist"
  "com.wrkflo.mac-bridges.plist"
)

usage() {
  cat <<EOF
usage: $(basename "$0") [push|pull|verify|all|--help]

Commands:
  push     sync VM-side bin/, scripts/, and relay scripts to the Mac repo
  pull     copy installed Mac LaunchAgent plists into mac-setup/
  verify   check SSH, relay endpoints, and Hammerspoon/LaunchAgent state
  all      run push, pull, then verify (default)
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
die() { printf '%s\n' "$*" >&2; exit 1; }
note() { printf '[dws-sync-mac] %s\n' "$*"; }
ok() { printf '[ok] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
quote() { printf '%q' "$1"; }

need_tool() {
  have "$1" || die "missing required tool: $1"
}

ssh_mac() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$MAC_SSH_HOST" "$@"
}

resolve_remote_paths() {
  local remote_home

  remote_home=$(ssh_mac "printf %s \"\$HOME\"") || die "failed to reach Mac over SSH: $MAC_SSH_HOST"
  [ -n "$remote_home" ] || die "failed to resolve remote home directory"

  MAC_REMOTE_HOME="$remote_home"
  MAC_REMOTE_REPO="${MAC_REMOTE_REPO:-${remote_home}/dev-workspace}"
  MAC_REMOTE_LAUNCH_AGENTS="${MAC_REMOTE_LAUNCH_AGENTS:-${remote_home}/Library/LaunchAgents}"
}

ensure_remote_repo_dirs() {
  ssh_mac "mkdir -p \
    $(quote "$MAC_REMOTE_REPO") \
    $(quote "$MAC_REMOTE_REPO/bin") \
    $(quote "$MAC_REMOTE_REPO/scripts") \
    $(quote "$MAC_REMOTE_REPO/mac-setup")"
}

push_cmd() {
  local rel
  local args=()

  resolve_remote_paths
  ensure_remote_repo_dirs
  for rel in "${PUSH_PATHS[@]}"; do
    args+=("$rel")
    note "queue push $rel"
  done
  git -C "$REPO_ROOT" ls-files -z -- "${args[@]}" | \
    rsync -az --from0 --files-from=- -e "$SSH_RSH" \
      "$REPO_ROOT/" \
      "$MAC_SSH_HOST:$MAC_REMOTE_REPO/"
  ok "pushed VM scripts to $MAC_REMOTE_REPO"
}

pull_cmd() {
  local plist

  resolve_remote_paths
  mkdir -p "$REPO_ROOT/mac-setup"
  for plist in "${MAC_LAUNCH_AGENTS[@]}"; do
    note "pull $MAC_SSH_HOST:$MAC_REMOTE_LAUNCH_AGENTS/$plist -> mac-setup/$plist"
    rsync -az -e "$SSH_RSH" \
      "$MAC_SSH_HOST:$MAC_REMOTE_LAUNCH_AGENTS/$plist" \
      "$REPO_ROOT/mac-setup/$plist"
  done
  ok "pulled Mac LaunchAgent configs into mac-setup/"
}

http_ok() {
  local url="$1"
  shift || true
  curl -fsS --max-time 3 "$url" "$@" >/dev/null 2>&1
}

print_status() {
  local label="$1" status="$2" detail="${3:-}"
  if [ "$status" = "ok" ]; then
    printf '[ok] %s%s\n' "$label" "${detail:+: $detail}"
  else
    printf '[warn] %s%s\n' "$label" "${detail:+: $detail}"
  fi
}

verify_cmd() {
  local uid chrome_agent bridges_agent hammerspoon_running chrome_local hammerspoon_local chrome_tailnet hammerspoon_tailnet failures=0

  resolve_remote_paths
  note "verify remote host $MAC_SSH_HOST"

  uid=$(ssh_mac 'id -u') || die "failed to query remote uid"

  if ssh_mac "launchctl print gui/$uid/com.wrkflo.chrome-cdp" >/dev/null 2>&1; then
    chrome_agent="loaded"
  else
    chrome_agent="missing"
  fi
  if ssh_mac "launchctl print gui/$uid/com.wrkflo.mac-bridges" >/dev/null 2>&1; then
    bridges_agent="loaded"
  else
    bridges_agent="missing"
  fi
  if ssh_mac 'pgrep -x Hammerspoon >/dev/null'; then
    hammerspoon_running="yes"
  else
    hammerspoon_running="no"
    failures=$((failures + 1))
  fi

  if ssh_mac 'curl -fsS --max-time 3 http://127.0.0.1:9222/json/version >/dev/null'; then
    chrome_local="ok"
  else
    chrome_local="fail"
    failures=$((failures + 1))
  fi
  if ssh_mac "curl -fsS --max-time 3 -X POST http://127.0.0.1:9223/apps -H 'Content-Type: application/json' -d '{}' >/dev/null"; then
    hammerspoon_local="ok"
  else
    hammerspoon_local="fail"
    failures=$((failures + 1))
  fi

  if http_ok "$MAC_CDP_URL/json/version"; then
    chrome_tailnet="ok"
  else
    chrome_tailnet="fail"
    failures=$((failures + 1))
  fi
  if http_ok "$MAC_GUI_URL/apps" -X POST -H 'Content-Type: application/json' -d '{}'; then
    hammerspoon_tailnet="ok"
  else
    hammerspoon_tailnet="fail"
    failures=$((failures + 1))
  fi

  print_status "ssh" ok "$MAC_SSH_HOST ($MAC_REMOTE_HOME)"
  print_status "launch agent com.wrkflo.chrome-cdp" "$([ "$chrome_agent" = "loaded" ] && echo ok || echo warn)" "$chrome_agent"
  print_status "launch agent com.wrkflo.mac-bridges" "$([ "$bridges_agent" = "loaded" ] && echo ok || echo warn)" "$bridges_agent"
  print_status "hammerspoon process" "$([ "$hammerspoon_running" = "yes" ] && echo ok || echo warn)" "$hammerspoon_running"
  print_status "chrome relay localhost" "$chrome_local" "http://127.0.0.1:9222/json/version"
  print_status "hammerspoon localhost" "$hammerspoon_local" "http://127.0.0.1:9223/apps"
  print_status "chrome relay tailnet" "$chrome_tailnet" "$MAC_CDP_URL/json/version"
  print_status "hammerspoon tailnet" "$hammerspoon_tailnet" "$MAC_GUI_URL/apps"

  if [ "$failures" -gt 0 ]; then
    warn "relay verification failed; suggested repair:"
    warn "ssh $MAC_SSH_HOST 'bash ~/dev-workspace/mac-setup/mac-bridges.sh'"
    return 1
  fi

  ok "Mac relay checks passed"
}

main() {
  local cmd="${1:-all}"

  need_tool ssh
  need_tool rsync
  need_tool curl
  need_tool git

  case "$cmd" in
    push) push_cmd ;;
    pull) pull_cmd ;;
    verify) verify_cmd ;;
    all)
      push_cmd
      pull_cmd
      verify_cmd
      ;;
    -h|--help|help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
