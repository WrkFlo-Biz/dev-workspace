# Termius setup (iPhone / iPad / laptop)

## Hosts to add

### 1. dev-workspace-vm
- **Address**: `20.230.203.79` (public) OR `dev-workspace-vm` (via Tailscale MagicDNS)
- **Username**: `moses`
- **Port**: `22`
- **Auth**: Key → import `~/.ssh/termius_20260415` (ED25519, no passphrase)
- **Startup command** *(optional but recommended)*:
  `cd ~/global-sentinel && exec codex --profile foundry`

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
| Codex — Global Sentinel     | `cd ~/global-sentinel && codex --profile foundry`     |
| Codex — gpt-5.4 xhigh       | `codex --profile foundry-5_4`                         |
| Codex — cheap fallback      | `codex --profile foundry-mini`                        |
| Claude Code                 | `claude`                                              |
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
