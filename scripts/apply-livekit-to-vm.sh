#!/usr/bin/env bash
# apply-livekit-to-vm.sh — push LiveKit env vars to the dev VM over Tailscale SSH.
# Run from Mac when Tailscale shows dev-workspace-vm as active.
# This file is .gitignore'd (*.env companion holds the actual values).

set -euo pipefail

VM_HOST="moses@100.117.16.63"
ENV_FILE="$(dirname "$0")/apply-livekit-to-vm.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: $ENV_FILE not found — create it with LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET"
  exit 1
fi

# shellcheck source=/dev/null
. "$ENV_FILE"

echo "[apply-livekit-to-vm] connecting to $VM_HOST..."

ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$VM_HOST" \
  LIVEKIT_URL="$LIVEKIT_URL" \
  LIVEKIT_API_KEY="$LIVEKIT_API_KEY" \
  LIVEKIT_API_SECRET="$LIVEKIT_API_SECRET" \
  bash -s <<'REMOTE'
set -euo pipefail

WRKFLO_CONFIG_DIR="$HOME/.config/wrkflo"
ENV_FILE="$WRKFLO_CONFIG_DIR/livekit.env"

mkdir -p "$WRKFLO_CONFIG_DIR"
cat >"$ENV_FILE" <<ENV
export LIVEKIT_URL="${LIVEKIT_URL}"
export LIVEKIT_API_KEY="${LIVEKIT_API_KEY}"
export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET}"
ENV
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE"

for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  if ! grep -q 'wrkflo/livekit.env' "$rc"; then
    printf '%s\n' '[ -f "$HOME/.config/wrkflo/livekit.env" ] && . "$HOME/.config/wrkflo/livekit.env"' >>"$rc"
    echo "added source to $rc"
  else
    echo "already sourced in $rc"
  fi
done

echo "done — LiveKit vars active in future shells on $(hostname)"
REMOTE

echo "[apply-livekit-to-vm] complete."
