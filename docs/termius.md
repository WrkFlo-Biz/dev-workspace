# Termius setup (iPhone / iPad / laptop)

## Hosts to add

### 1. dev-workspace-vm
- **Address**: `20.230.203.79` (public) OR `dev-workspace-vm` (via Tailscale MagicDNS)
- **Username**: `moses`
- **Port**: `22`
- **Auth**: Key → import `~/.ssh/termius_20260415` (ED25519, no passphrase)
- **Startup command**: leave blank, or use `exec bash -l`
  so login drops into the shared `dev-workspace` launcher. Do **not**
  hard-code a single repo here if you want cross-project access from the VM.

### 2. Mac (this computer)
- **Address**: `<mac-hostname>` via Tailscale MagicDNS
  (find with `tailscale status` on the Mac after login)
- **Username**: `mosestut`
- **Port**: `22`
- **Auth**: same key `termius_20260415` (already added to Mac by `authorize-vm.sh`,
  or manually paste the public key into `~/.ssh/authorized_keys`).

## Snippets to save in Termius

Terminus supports "Snippets" — canned commands. Useful ones:

| Snippet name                | Command                                               |
|-----------------------------|-------------------------------------------------------|
| Shared launcher             | `exec bash -l`                                        |
| Codex — shared workspace    | `cd ~/projects && codex --profile foundry --search --dangerously-bypass-approvals-and-sandbox --add-dir "$HOME"` |
| Codex — gpt-5.4 xhigh       | `cd ~/projects && codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox --add-dir "$HOME"` |
| Claude Code                 | `cd ~/projects && claude --dangerously-skip-permissions --add-dir "$HOME"` |
| Sync Mac → VM               | `~/dev-workspace/scripts/sync-mac-to-vm.sh <path>`    |
| VM status                   | `systemctl --user status; tailscale status`            |

## Port forwarding (optional)

Termius "Port forwarding" can forward a local port over SSH — handy for
previewing a webapp running on the VM in your phone's browser:

- Local: `8080`
- Remote host: `localhost`
- Remote port: `3000` (or whatever the app binds to)

Then open `http://localhost:8080` in Safari on the phone.

## Keep-alive

Enable "Keep alive" in the host settings (interval ≈ 60s) so sessions survive
moving between Wi-Fi networks.
