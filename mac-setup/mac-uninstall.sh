#!/usr/bin/env bash
# mac-uninstall.sh — remove the dev-workspace LaunchAgents from a Mac.

set -euo pipefail

log() { printf '\033[1;34m[mac-uninstall]\033[0m %s\n' "$*"; }

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLISTS=(
  "com.wrkflo.chrome-cdp.plist"
  "com.wrkflo.mac-bridges.plist"
)

mkdir -p "$LAUNCH_AGENTS_DIR"

for plist_name in "${PLISTS[@]}"; do
  plist_path="$LAUNCH_AGENTS_DIR/$plist_name"
  launchctl unload -w "$plist_path" >/dev/null 2>&1 || true
  if [ -f "$plist_path" ]; then
    rm -f "$plist_path"
    log "Removed $plist_path"
  else
    log "$plist_path already absent"
  fi
done

log "LaunchAgents removed"
