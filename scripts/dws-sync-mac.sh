#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

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
  verify   read-only parity + prerequisite check; report drift without syncing
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

remote_ok() {
  ssh_mac "$@" >/dev/null 2>&1
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

emit_lines() {
  local lines="$1"
  [ -n "$lines" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %s\n' "$line"
  done <<EOF
$lines
EOF
}

collect_repo_drift() {
  local args=()
  local rel

  for rel in "${PUSH_PATHS[@]}"; do
    args+=("$rel")
  done

  git -C "$REPO_ROOT" ls-files -z -- "${args[@]}" | \
    rsync -aznic --from0 --files-from=- -e "$SSH_RSH" \
      --out-format='%i %n%L' \
      "$REPO_ROOT/" \
      "$MAC_SSH_HOST:$MAC_REMOTE_REPO/"
}

collect_launch_agent_drift() {
  local plist="$1"
  rsync -aznic -e "$SSH_RSH" \
    --out-format='%i %n%L' \
    "$REPO_ROOT/mac-setup/$plist" \
    "$MAC_SSH_HOST:$MAC_REMOTE_LAUNCH_AGENTS/$plist"
}

report_drift_block() {
  local label="$1"
  local remediation="$2"
  local lines="$3"

  if [ -n "$lines" ]; then
    print_status "$label" drift "$remediation"
    emit_lines "$lines"
    return 1
  fi

  print_status "$label" ok
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
  local uid chrome_agent bridges_agent hammerspoon_running chrome_local hammerspoon_local chrome_tailnet hammerspoon_tailnet
  local repo_dir_status launch_agents_dir_status remote_tailscale_ip repo_drift remote_repo_drift
  local chrome_plist_drift bridges_plist_drift hammerspoon_init chrome_app hammerspoon_app socat_ok tailscale_ok
  local failures=0

  resolve_remote_paths
  note "verify remote host $MAC_SSH_HOST"
  note "verify is read-only: drift is reported, no files are copied"

  uid=$(ssh_mac 'id -u') || die "failed to query remote uid"

  if remote_ok "[ -d $(quote "$MAC_REMOTE_REPO") ]"; then
    repo_dir_status="present"
  else
    repo_dir_status="missing"
    failures=$((failures + 1))
  fi

  if remote_ok "[ -d $(quote "$MAC_REMOTE_LAUNCH_AGENTS") ]"; then
    launch_agents_dir_status="present"
  else
    launch_agents_dir_status="missing"
    failures=$((failures + 1))
  fi

  if remote_ok 'command -v tailscale'; then
    tailscale_ok="yes"
    remote_tailscale_ip=$(ssh_mac 'tailscale ip -4 2>/dev/null | head -1 || true')
    if [ -z "$remote_tailscale_ip" ]; then
      tailscale_ok="no-ip"
      failures=$((failures + 1))
    fi
  else
    tailscale_ok="no"
    remote_tailscale_ip=""
    failures=$((failures + 1))
  fi

  if remote_ok 'command -v socat'; then
    socat_ok="yes"
  else
    socat_ok="no"
    failures=$((failures + 1))
  fi

  if remote_ok "[ -d /Applications/Google\\ Chrome.app ] || [ -d \"\$HOME/Applications/Google Chrome.app\" ]"; then
    chrome_app="present"
  else
    chrome_app="missing"
    failures=$((failures + 1))
  fi

  if remote_ok "[ -d /Applications/Hammerspoon.app ] || [ -d \"\$HOME/Applications/Hammerspoon.app\" ]"; then
    hammerspoon_app="present"
  else
    hammerspoon_app="missing"
    failures=$((failures + 1))
  fi

  if remote_ok "[ -f \"\$HOME/.hammerspoon/init.lua\" ]"; then
    hammerspoon_init="present"
  else
    hammerspoon_init="missing"
    failures=$((failures + 1))
  fi

  if remote_ok "launchctl print gui/$uid/com.wrkflo.chrome-cdp"; then
    chrome_agent="loaded"
  else
    chrome_agent="missing"
    failures=$((failures + 1))
  fi
  if remote_ok "launchctl print gui/$uid/com.wrkflo.mac-bridges"; then
    bridges_agent="loaded"
  else
    bridges_agent="missing"
    failures=$((failures + 1))
  fi
  if remote_ok 'pgrep -x Hammerspoon'; then
    hammerspoon_running="yes"
  else
    hammerspoon_running="no"
    failures=$((failures + 1))
  fi

  if [ "$repo_dir_status" = "present" ]; then
    if remote_repo_drift=$(collect_repo_drift 2>/dev/null); then
      repo_drift="$remote_repo_drift"
      if [ -n "$repo_drift" ]; then
        failures=$((failures + 1))
      fi
    else
      repo_drift="failed to compare $REPO_ROOT against $MAC_REMOTE_REPO"
      failures=$((failures + 1))
    fi
  else
    repo_drift="remote repo missing at $MAC_REMOTE_REPO"
  fi

  if [ "$launch_agents_dir_status" = "present" ]; then
    if chrome_plist_drift=$(collect_launch_agent_drift "com.wrkflo.chrome-cdp.plist" 2>/dev/null); then
      if [ -n "$chrome_plist_drift" ]; then
        failures=$((failures + 1))
      fi
    else
      chrome_plist_drift="failed to compare com.wrkflo.chrome-cdp.plist"
      failures=$((failures + 1))
    fi

    if bridges_plist_drift=$(collect_launch_agent_drift "com.wrkflo.mac-bridges.plist" 2>/dev/null); then
      if [ -n "$bridges_plist_drift" ]; then
        failures=$((failures + 1))
      fi
    else
      bridges_plist_drift="failed to compare com.wrkflo.mac-bridges.plist"
      failures=$((failures + 1))
    fi
  else
    chrome_plist_drift="remote LaunchAgents dir missing at $MAC_REMOTE_LAUNCH_AGENTS"
    bridges_plist_drift="remote LaunchAgents dir missing at $MAC_REMOTE_LAUNCH_AGENTS"
  fi

  if remote_ok 'curl -fsS --max-time 3 http://127.0.0.1:9222/json/version'; then
    chrome_local="ok"
  else
    chrome_local="fail"
    failures=$((failures + 1))
  fi
  if remote_ok "curl -fsS --max-time 3 -X POST http://127.0.0.1:9223/apps -H 'Content-Type: application/json' -d '{}'"; then
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
  print_status "remote repo" "$([ "$repo_dir_status" = "present" ] && echo ok || echo warn)" "$MAC_REMOTE_REPO ($repo_dir_status)"
  print_status "remote launch agents dir" "$([ "$launch_agents_dir_status" = "present" ] && echo ok || echo warn)" "$MAC_REMOTE_LAUNCH_AGENTS ($launch_agents_dir_status)"
  print_status "tailscale CLI" "$([ "$tailscale_ok" = "yes" ] && echo ok || echo warn)" "${remote_tailscale_ip:-${tailscale_ok}}"
  print_status "socat" "$([ "$socat_ok" = "yes" ] && echo ok || echo warn)" "$socat_ok"
  print_status "Google Chrome.app" "$([ "$chrome_app" = "present" ] && echo ok || echo warn)" "$chrome_app"
  print_status "Hammerspoon.app" "$([ "$hammerspoon_app" = "present" ] && echo ok || echo warn)" "$hammerspoon_app"
  print_status "Hammerspoon init.lua" "$([ "$hammerspoon_init" = "present" ] && echo ok || echo warn)" "$hammerspoon_init"
  print_status "launch agent com.wrkflo.chrome-cdp" "$([ "$chrome_agent" = "loaded" ] && echo ok || echo warn)" "$chrome_agent"
  print_status "launch agent com.wrkflo.mac-bridges" "$([ "$bridges_agent" = "loaded" ] && echo ok || echo warn)" "$bridges_agent"
  print_status "hammerspoon process" "$([ "$hammerspoon_running" = "yes" ] && echo ok || echo warn)" "$hammerspoon_running"
  if ! report_drift_block "repo parity" "run $(basename "$0") push to sync VM -> Mac repo" "$repo_drift"; then
    :
  fi
  if ! report_drift_block "launch agent parity: com.wrkflo.chrome-cdp" "run $(basename "$0") pull to snapshot installed plist, or copy mac-setup/com.wrkflo.chrome-cdp.plist to the Mac if local is source of truth" "$chrome_plist_drift"; then
    :
  fi
  if ! report_drift_block "launch agent parity: com.wrkflo.mac-bridges" "run $(basename "$0") pull to snapshot installed plist, or copy mac-setup/com.wrkflo.mac-bridges.plist to the Mac if local is source of truth" "$bridges_plist_drift"; then
    :
  fi
  print_status "chrome relay localhost" "$chrome_local" "http://127.0.0.1:9222/json/version"
  print_status "hammerspoon localhost" "$hammerspoon_local" "http://127.0.0.1:9223/apps"
  print_status "chrome relay tailnet" "$chrome_tailnet" "$MAC_CDP_URL/json/version"
  print_status "hammerspoon tailnet" "$hammerspoon_tailnet" "$MAC_GUI_URL/apps"

  if [ "$failures" -gt 0 ]; then
    warn "verify failed; suggested repair order:"
    warn "$(basename "$0") push"
    warn "$(basename "$0") pull"
    warn "ssh $MAC_SSH_HOST 'bash ~/dev-workspace/mac-setup/mac-bridges.sh'"
    return 1
  fi

  ok "Mac sync and relay checks passed"
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
