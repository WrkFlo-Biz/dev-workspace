#!/usr/bin/env bash
# mac-setup/bootstrap.sh — run ONCE on your Mac.
# Needs sudo. Safe to re-run.
#
# What this does:
#   1. Enables Remote Login (SSH) so Termius + VM can reach this Mac
#   2. Enables Remote Management (ARD) for all users, all privileges
#      (superset of Screen Sharing)
#   3. Enables File Sharing (SMB) so other Tailscale nodes can mount folders
#   4. Installs the Tailscale .app via brew cask if missing
#   5. Installs mas (Mac App Store CLI) nothing — Tailscale is cask-only here
#
# After this finishes, open Tailscale.app from your menu bar and log in with
# your @wrkflo.biz Google account so the Mac joins the same tailnet as the VM.

set -euo pipefail
log() { printf '\033[1;34m[mac-setup]\033[0m %s\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Don't run this as root directly — it uses sudo where needed."
  exit 1
fi

log "1/4  Enable Remote Login (SSH)"
sudo systemsetup -setremotelogin on

log "2/4  Enable Remote Management (ARD) — all users, all privileges"
# kickstart is the canonical Apple tool for this. -all -privs enables every
# ARD capability (observe, control, send messages, restart, copy files, etc.).
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -restart -agent -privs -all

log "3/4  Enable File Sharing (SMB) for current user"
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.smbd.plist 2>/dev/null || true
# Make the current user shareable over SMB. Uses dscl to set the required ACL.
sudo dscl . -append /Groups/com.apple.access_smb GroupMembership "$USER" 2>/dev/null || true

log "4/4  Install Tailscale.app if missing"
if ! brew list --cask tailscale-app >/dev/null 2>&1; then
  brew install --cask tailscale-app
fi

log "done. Now:"
log "  - Open Tailscale from the menu bar, log in with your @wrkflo.biz Google"
log "  - Run: ./mac-setup/authorize-vm.sh   (adds the VM's SSH public key so"
log "    codex on the VM can ssh back to the Mac passwordlessly)"
