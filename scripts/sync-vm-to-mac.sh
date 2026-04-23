#!/usr/bin/env bash
# sync-vm-to-mac.sh — pull a remote VM folder down to the Mac.
# Mirror of sync-mac-to-vm.sh but the other direction.

set -euo pipefail
REMOTE="${1:?usage: $0 <remote-path> [local-path]}"
LOCAL="${2:-$(basename "$REMOTE")}"
VM_HOST="${VM_HOST:-moses@20.230.203.79}"

rsync -avz --delete \
  --exclude='.git/' --exclude='node_modules/' --exclude='.venv/' \
  --exclude='__pycache__/' --exclude='.DS_Store' --exclude='dist/' \
  --exclude='build/' --exclude='.next/' --exclude='*.log' \
  "$VM_HOST:$REMOTE/" "$LOCAL/"
