#!/usr/bin/env bash
# dws-sessions-init.sh — lightweight boot init for the dev workspace
#
# Previous version spawned 10 persistent codex tmux sessions on boot.
# That architecture was removed (2026-04-24) because 10 codex processes
# on a 2-core VM caused chronic resource exhaustion.
#
# New model: the wrkflo-orchestrator API is the only always-on service.
# Interactive codex/claude sessions are created on-demand by the launcher.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-${HOME}/projects}"
FOUNDRY_ENV_PATH="${DWS_FOUNDRY_ENV_PATH:-${HOME}/.config/wrkflo/foundry.env}"

log() {
  printf '%s [sessions-init] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  log "error: $*"
  exit 1
}

# Ensure foundry env exists (needed by any codex session the launcher starts)
if [ -f "$FOUNDRY_ENV_PATH" ]; then
  log "foundry env present: ${FOUNDRY_ENV_PATH}"
else
  log "warning: foundry env missing: ${FOUNDRY_ENV_PATH}"
fi

# Ensure project directories exist
for proj_dir in "$PROJECTS_ROOT"/*/; do
  [ -d "$proj_dir" ] || continue
  proj_name=$(basename "$proj_dir")
  log "project: ${proj_name}"
done

# Start the wrkflo-orchestrator API service if the unit exists
if systemctl --user cat wrkflo-orchestrator-api.service >/dev/null 2>&1; then
  if systemctl --user is-active --quiet wrkflo-orchestrator-api.service; then
    log "orchestrator API: already running"
  else
    systemctl --user start wrkflo-orchestrator-api.service
    log "orchestrator API: started"
  fi
else
  log "orchestrator API: unit not installed (skipping)"
fi

log "sessions init complete (on-demand model -- no persistent sessions)"
