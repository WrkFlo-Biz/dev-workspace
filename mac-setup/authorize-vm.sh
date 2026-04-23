#!/usr/bin/env bash
# authorize-vm.sh — let the dev-workspace-vm SSH INTO this Mac passwordlessly.
# That is what allows codex on the VM to edit files on your Mac.
#
# Safe to re-run; only appends if the VM key isn't already in authorized_keys.

set -euo pipefail
log() { printf '\033[1;34m[authorize-vm]\033[0m %s\n' "$*"; }

VM_HOST="${VM_HOST:-moses@20.230.203.79}"

log "fetching VM SSH public key from $VM_HOST"
VM_PUB=$(ssh -o BatchMode=yes "$VM_HOST" '
  if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -C "moses@dev-workspace-vm" -f ~/.ssh/id_ed25519 >/dev/null
  fi
  cat ~/.ssh/id_ed25519.pub
')

mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"

if grep -qxF "$VM_PUB" "$HOME/.ssh/authorized_keys"; then
  log "VM key already authorized — nothing to do."
else
  printf '\n# Added by dev-workspace/mac-setup/authorize-vm.sh on %s\n%s\n' \
    "$(date -u +%F)" "$VM_PUB" >>"$HOME/.ssh/authorized_keys"
  log "appended VM key to ~/.ssh/authorized_keys"
fi

log "test it from the VM: ssh $USER@$(hostname).local 'uname -a'"
log "(or use the Mac's Tailscale IP once Tailscale is up on both ends)"
