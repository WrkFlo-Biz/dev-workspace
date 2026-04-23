# Setup log (what actually got run)

This documents the exact state that was applied on 2026-04-23 when the repo was
first bootstrapped. Re-reading this later is faster than re-running every script.

## Azure VM (`dev-workspace-vm`)

- Already existed from prior work.
- Installed Tailscale:
  `ssh moses@20.230.203.79 'curl -fsSL https://tailscale.com/install.sh | sudo sh'`
- Started Tailscale with SSH + MagicDNS hostname:
  `sudo tailscale up --ssh --operator=moses --hostname=dev-workspace-vm --accept-routes`
  → printed auth URL `https://login.tailscale.com/a/1a559b4601b3c0` — click once to
  register the VM on the tailnet.

## Mac

- `NOPASSWD` sudo granted via `/etc/sudoers.d/mosestut-nopasswd`
  so repeat runs don't need a password. Reverse with
  `sudo rm /etc/sudoers.d/mosestut-nopasswd` if you want to undo.
- **Remote Login (SSH)**: `sudo systemsetup -setremotelogin on` — already on.
- **Remote Management (ARD)**: `kickstart -users mosestut -privs -all`.
  All ARD privileges granted to the `mosestut` account.
- **SMB**: already active via existing launchd plists; Public folders shared.
  Full-home access via SSH/SFTP which is sufficient.
- **Tailscale.app**: `brew install --cask tailscale-app`.
  Open it from `/Applications/Tailscale.app` and log in to join the tailnet.
- **authorized_keys** on Mac now contains:
  - VM SSH public key (`moses@dev-workspace-vm`) → VM → Mac passwordless
  - Termius public key (`termius-20260415`) → phone → Mac

## Codex profiles

- `codex-profiles/foundry-profiles.toml` is the source of truth. Apply with
  `scripts/apply-codex-profiles.sh` on any new machine.
- Existing profiles on this Mac + VM: `foundry`, `foundry-mini`, `foundry-5_4`
  (already configured in prior work).
- New profiles to add: `foundry-4o`, `foundry-opus`, `foundry-sonnet`.

## GitHub repo

- `Wrk-Flo/dev-workspace` (private).
- This Mac's checkout lives at `~/dev-workspace`.

## Still-manual steps (one-time, user-action only)

1. Click Tailscale VM auth URL once to register the VM.
2. Open `/Applications/Tailscale.app` on the Mac → sign in with the same
   `@wrkflo.biz` Google account → approve the network extension when macOS asks.
3. On your phone: install Tailscale from the App Store, sign in with the same
   account; install Termius, import `~/.ssh/termius_20260415`, add two hosts
   (VM + Mac) per `docs/termius.md`.
