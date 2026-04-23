#!/usr/bin/env bash
# mac-setup.sh — idempotent bootstrap for a Mac that should join the
# dev-workspace environment.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { printf '\033[1;34m[mac-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[mac-setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[mac-setup]\033[0m %s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET_REPO="$HOME/dev-workspace"
DESKTOP_LAUNCHER="$HOME/Desktop/Dev Workspace.command"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
VM_USER="${VM_USER:-moses}"
VM_HOSTS=("dev-workspace-vm" "100.117.16.63" "20.230.203.79")
REPO_URL="${REPO_URL:-}"
PUBKEY_PATH=""
SSH_RESULT="not tested"

ensure_brew_in_path() {
  if have brew; then
    return 0
  fi
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    return 0
  fi
  if [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
    return 0
  fi
  return 1
}

ensure_homebrew() {
  if ensure_brew_in_path; then
    log "Homebrew already installed"
    return
  fi

  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ensure_brew_in_path || die "Homebrew install completed but brew is still unavailable"
}

install_formula_if_missing() {
  local formula=$1
  if brew list "$formula" >/dev/null 2>&1; then
    log "$formula already installed"
  else
    log "Installing $formula"
    brew install "$formula"
  fi
}

resolve_repo_url() {
  if [ -n "$REPO_URL" ]; then
    return
  fi
  REPO_URL=$(git -C "$SOURCE_REPO_ROOT" remote get-url origin 2>/dev/null || true)
  REPO_URL=${REPO_URL:-git@github.com:Wrk-Flo/dev-workspace.git}
}

sync_repo() {
  resolve_repo_url
  mkdir -p "$TARGET_REPO"

  if [ -d "$TARGET_REPO/.git" ]; then
    log "Updating existing repo at $TARGET_REPO"
    git -C "$TARGET_REPO" pull --ff-only
    return
  fi

  if [ -n "$(find "$TARGET_REPO" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    die "$TARGET_REPO exists but is not a git checkout; refusing to overwrite it"
  fi

  log "Cloning $REPO_URL into $TARGET_REPO"
  git clone "$REPO_URL" "$TARGET_REPO"
}

install_desktop_launcher() {
  mkdir -p "$HOME/Desktop"
  cp "$TARGET_REPO/mac-setup/dev-workspace.command" "$DESKTOP_LAUNCHER"
  chmod +x "$DESKTOP_LAUNCHER"
  log "Installed desktop launcher at $DESKTOP_LAUNCHER"
}

reload_launch_agent() {
  local plist_name=$1
  local src="$TARGET_REPO/mac-setup/$plist_name"
  local dest="$LAUNCH_AGENTS_DIR/$plist_name"

  install -m 0644 "$src" "$dest"
  launchctl unload -w "$dest" >/dev/null 2>&1 || true
  launchctl load -w "$dest"
  log "Loaded LaunchAgent $plist_name"
}

install_launch_agents() {
  mkdir -p "$LAUNCH_AGENTS_DIR"
  reload_launch_agent "com.wrkflo.chrome-cdp.plist"
  reload_launch_agent "com.wrkflo.mac-bridges.plist"
}

ensure_ssh_key() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  PUBKEY_PATH=$(find "$HOME/.ssh" -maxdepth 1 -type f -name '*.pub' | sort | head -1 || true)
  if [ -z "$PUBKEY_PATH" ]; then
    PUBKEY_PATH="$HOME/.ssh/id_ed25519.pub"
    log "Generating SSH key at ${PUBKEY_PATH%.pub}"
    ssh-keygen -t ed25519 -N "" \
      -C "${USER}@$(scutil --get ComputerName 2>/dev/null || hostname)" \
      -f "${PUBKEY_PATH%.pub}"
  else
    log "Using existing SSH public key at $PUBKEY_PATH"
  fi

  printf '\n%s\n%s\n%s\n\n' \
    "Add this SSH public key to dev-workspace-vm:" \
    "$(cat "$PUBKEY_PATH")" \
    "End SSH public key"
}

test_vm_ssh() {
  local host
  local output

  for host in "${VM_HOSTS[@]}"; do
    log "Testing SSH connectivity to $VM_USER@$host"
    output=$(ssh \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "$VM_USER@$host" "printf connected" 2>&1) && {
      SSH_RESULT="ok via $host"
      log "SSH connectivity succeeded via $host"
      return
    }
    warn "SSH test failed via $host: ${output##*$'\n'}"
  done

  SSH_RESULT="failed; add the printed public key to dev-workspace-vm and retry"
}

print_summary() {
  printf '\nSummary\n'
  printf '  %-18s %s\n' "repo" "$TARGET_REPO"
  printf '  %-18s %s\n' "desktop launcher" "$DESKTOP_LAUNCHER"
  printf '  %-18s %s\n' "launch agents" "com.wrkflo.chrome-cdp, com.wrkflo.mac-bridges"
  printf '  %-18s %s\n' "ssh key" "$PUBKEY_PATH"
  printf '  %-18s %s\n' "ssh test" "$SSH_RESULT"
  printf '  %-18s %s\n' "tailscale cli" "$(command -v tailscale || echo missing)"
  printf '  %-18s %s\n' "socat" "$(command -v socat || echo missing)"

  if [ ! -d "/Applications/Google Chrome.app" ]; then
    warn "Google Chrome.app not found; the 9222 browser bridge will not start until Chrome is installed"
  fi
  if [ ! -d "/Applications/Hammerspoon.app" ] && [ ! -d "$HOME/Applications/Hammerspoon.app" ]; then
    warn "Hammerspoon.app not found; the 9223 GUI bridge will stay inactive until it is installed"
  fi
}

main() {
  ensure_homebrew
  install_formula_if_missing "tailscale"
  install_formula_if_missing "socat"
  sync_repo
  install_desktop_launcher
  install_launch_agents
  ensure_ssh_key
  test_vm_ssh
  print_summary
}

main "$@"
