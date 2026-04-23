#!/usr/bin/env bash

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export MAC_GUI_URL="${MAC_GUI_URL:-http://100.78.207.22:9223}"
export MAC_CDP_URL="${MAC_CDP_URL:-http://100.78.207.22:9222}"
export MAC_SSH_HOST="${MAC_SSH_HOST:-mosestut@100.78.207.22}"

PROJECTS=(
  global-sentinel
  wrkflo-voice-agents-ops
  openclaw-prod
  global-sentinel-azure-quantum
  wrkflo-orchestrator
  dev-workspace
)

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
bold() { color '1' "$1"; }
dim() { color '2' "$1"; }
green() { color '32' "$1"; }
cyan() { color '36' "$1"; }
yellow() { color '33' "$1"; }
red() { color '31' "$1"; }

proj_name() {
  case "$1" in
    [1-6]) printf '%s\n' "${PROJECTS[$(($1 - 1))]}" ;;
    *) printf '\n' ;;
  esac
}

proj_short() {
  case "$1" in
    global-sentinel) echo "gs" ;;
    wrkflo-voice-agents-ops) echo "voice" ;;
    openclaw-prod) echo "oclaw" ;;
    global-sentinel-azure-quantum) echo "gsaq" ;;
    wrkflo-orchestrator) echo "orch" ;;
    dev-workspace) echo "dws" ;;
    *) echo "proj" ;;
  esac
}

profile_for() {
  case "$1" in
    1) echo "foundry-5_4" ;; 2) echo "foundry-5_2" ;; 3) echo "foundry-codex" ;;
    4) echo "foundry-mini" ;; 5) echo "foundry-5-mini" ;; 6) echo "foundry-4o" ;;
    7) echo "foundry-opus" ;; 8) echo "foundry-sonnet" ;; 9) echo "foundry-haiku" ;;
    *) echo "" ;;
  esac
}

model_label() {
  case "$1" in
    1) echo "5-4" ;; 2) echo "5-2" ;; 3) echo "codex" ;; 4) echo "mini" ;;
    5) echo "5mini" ;; 6) echo "4o" ;; 7) echo "opus" ;; 8) echo "sonnet" ;;
    9) echo "haiku" ;; c|C) echo "claude" ;; *) echo "?" ;;
  esac
}
