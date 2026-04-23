#!/usr/bin/env bash
# sync-mac-to-vm.sh — push a local Mac folder up to the VM so codex there can work on it.
# Usage: scripts/sync-mac-to-vm.sh ~/some/project            # default target: ~/some on VM
#        scripts/sync-mac-to-vm.sh ~/some/project remote/dir # explicit remote path
#
# Uses rsync over SSH; excludes node_modules, .venv, build artifacts.

set -euo pipefail

SRC="${1:?usage: $0 <local-path> [remote-path]}"
REMOTE="${2:-$(basename "$SRC")}"
VM_HOST="${VM_HOST:-moses@20.230.203.79}"

rsync -avz --delete \
  --exclude='.git/' --exclude='node_modules/' --exclude='.venv/' \
  --exclude='__pycache__/' --exclude='.DS_Store' --exclude='dist/' \
  --exclude='build/' --exclude='.next/' --exclude='*.log' \
  "$SRC/" "$VM_HOST:$REMOTE/"
