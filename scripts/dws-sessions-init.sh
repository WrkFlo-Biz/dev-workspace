#!/usr/bin/env bash
# dws-sessions-init.sh — lightweight boot init for the dev workspace
#
# Previous version spawned 10 persistent codex tmux sessions on boot.
# That architecture was removed (2026-04-24) because 10 codex processes
# on a 2-core VM caused chronic resource exhaustion.
#
# New model: boot-time init is intentionally lightweight.
# Orchestrator services and interactive codex/claude sessions are launched
# on-demand by the operator or launcher instead of being forced on at boot.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-${HOME}/projects}"
FOUNDRY_ENV_PATH="${DWS_FOUNDRY_ENV_PATH:-${HOME}/.config/wrkflo/foundry.env}"
ORCHESTRATOR_UNIT="${DWS_ORCHESTRATOR_UNIT:-wrkflo-orchestrator-api.service}"

log() {
  printf '%s [sessions-init] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  log "error: $*"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
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

# Report orchestrator availability, but keep it on-demand.
if ! have systemctl; then
  log "orchestrator API: systemctl unavailable (on-demand; state check skipped)"
elif ! systemctl --user show default.target >/dev/null 2>&1; then
  log "orchestrator API: user systemd unavailable (on-demand; state check skipped)"
elif systemctl --user cat "$ORCHESTRATOR_UNIT" >/dev/null 2>&1; then
  if systemctl --user is-active --quiet "$ORCHESTRATOR_UNIT"; then
    log "orchestrator API: already running (left untouched)"
  else
    log "orchestrator API: installed but left stopped (on-demand)"
  fi
else
  log "orchestrator API: unit not installed (on-demand)"
fi

log "sessions init complete (on-demand model -- no persistent sessions)"
