#!/usr/bin/env bash
# vm-bootstrap.sh — idempotent setup for the dev-workspace-vm.
# Run on the VM itself (ssh moses@20.230.203.79 then bash).
# Safe to re-run; each step skips if already done.

set -euo pipefail

log() { printf '\033[1;34m[vm-bootstrap]\033[0m %s\n' "$*"; }

# 1. Package basics
if ! command -v gh >/dev/null; then
  log "installing gh, az, jq, rsync"
  sudo apt-get update -y
  sudo apt-get install -y jq rsync unzip
  # gh + az assumed preinstalled on this VM; skip if already there
fi

# 2. Node + Codex CLI
if ! command -v codex >/dev/null; then
  log "installing codex-cli globally via npm"
  # Requires node. If not present, install via nvm in ~/.nvm
  if ! command -v node >/dev/null; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
  fi
  npm install -g @openai/codex
fi

# 3. Claude Code
if ! command -v claude >/dev/null; then
  log "installing claude-code"
  curl -fsSL https://claude.ai/install.sh | bash || true
fi

# 4. Tailscale
if ! command -v tailscale >/dev/null; then
  log "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sudo sh
fi

# Bring Tailscale up (idempotent — --ssh enables Tailscale SSH)
if ! sudo tailscale status >/dev/null 2>&1; then
  log "run: sudo tailscale up --ssh --operator=$USER --hostname=$(hostname)"
  log "then click the URL printed to authorize this device."
fi

# 5. Codex Foundry profile + key auto-load
if [ ! -f "$HOME/.config/wrkflo/foundry.env" ]; then
  log "fetching Azure Foundry key via az (requires az login on VM)"
  mkdir -p "$HOME/.config/wrkflo"
  KEY=$(az cognitiveservices account keys list \
    -g rg-moses-8586 -n moses-8586-resource --query key1 -o tsv)
  cat >"$HOME/.config/wrkflo/foundry.env" <<ENV
export AZURE_OPENAI_API_KEY="$KEY"
ENV
  chmod 600 "$HOME/.config/wrkflo/foundry.env"
fi

# Auto-load the key in future shells
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  if ! grep -q 'wrkflo/foundry.env' "$rc"; then
    echo '[ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"' >>"$rc"
  fi
done

log "done. run: codex --profile foundry"
