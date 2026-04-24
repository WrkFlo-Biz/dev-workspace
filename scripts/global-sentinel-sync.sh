#!/usr/bin/env bash
# global-sentinel-sync.sh — periodic sync of global-sentinel between Mac and VM.
# Called by com.wrkflo.global-sentinel-sync LaunchAgent every 5 min.
# Also runs on login when GLOBAL_SENTINEL_SYNC_LOGIN=1.

set -euo pipefail

GS_LOCAL="${GS_LOCAL:-$HOME/global-sentinel}"
VM_HOST="${VM_HOST:-moses@dev-workspace-vm}"
GS_REMOTE="projects/global-sentinel"
LOG_TAG="[gs-sync]"

log() { printf '%s %s %s\n' "$(date +%H:%M:%S)" "$LOG_TAG" "$*"; }

if [ ! -d "$GS_LOCAL/.git" ]; then
  log "no local repo at $GS_LOCAL, skipping"
  exit 0
fi

if ! ping -c1 -W2 dev-workspace-vm >/dev/null 2>&1; then
  log "VM unreachable, skipping"
  exit 0
fi

cd "$GS_LOCAL"

# Pull remote changes if working tree is clean
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  log "pulling latest..."
  git fetch origin --quiet 2>/dev/null || true
  LOCAL_HEAD=$(git rev-parse HEAD)
  REMOTE_HEAD=$(git rev-parse origin/main 2>/dev/null || echo "$LOCAL_HEAD")
  if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
    git pull --rebase --quiet origin main 2>/dev/null && log "updated to $(git rev-parse --short HEAD)" || log "pull failed"
  else
    log "already up to date"
  fi
else
  log "dirty working tree, skipping git pull"
fi

# Sync analysis outputs to VM (these aren't in git)
ANALYSIS_DIR="$GS_LOCAL/data/analysis"
if [ -d "$ANALYSIS_DIR" ]; then
  rsync -az --delete \
    --exclude='*.log' --exclude='.DS_Store' \
    "$ANALYSIS_DIR/" "$VM_HOST:$GS_REMOTE/data/analysis/" 2>/dev/null \
    && log "synced analysis data to VM" \
    || log "rsync to VM failed (VM may be down)"
fi

if [ "${GLOBAL_SENTINEL_SYNC_LOGIN:-}" = "1" ]; then
  log "login sync complete"
fi
