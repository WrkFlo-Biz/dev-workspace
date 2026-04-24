# Termius (Phone) Setup Guide

Access the dev workspace from iPhone via Termius SSH client.

## Host Configuration

| Field | Value |
|-------|-------|
| Label | Dev Workspace |
| Hostname | dev-workspace-vm |
| Fallback IP | 20.230.203.79 |
| Tailscale IP | 100.117.16.63 |
| Port | 22 |
| Username | moses |
| Auth | SSH key (import from Mac keychain or generate in Termius) |

Use the Tailscale hostname when on the mesh. Use the public IP as fallback.

## First connect

1. SSH in — the launcher auto-runs and shows the project picker.
2. Pick a project (1-6), then pick a model (1-9 or c for Claude).
3. Session launches inside tmux — survives disconnects.

## Reconnecting

When you SSH back in after a disconnect:
- The launcher shows active tmux sessions at the top.
- Press **r** to reconnect. If only one session exists, it auto-attaches.
- To pick from multiple sessions, press r then enter the session name or number.

## tmux shortcuts (prefix = Ctrl-a)

| Keys | Action |
|------|--------|
| Ctrl-a d | Detach (leave session running, exit SSH) |
| Ctrl-a c | New window |
| Ctrl-a n / p | Next / previous window |
| Ctrl-a \| | Split pane vertical |
| Ctrl-a - | Split pane horizontal |
| Ctrl-a h | Health dashboard popup |
| Ctrl-a [ | Scroll mode (vi keys, q to exit) |

## Termius snippets (optional)

Save these as snippets for quick access:

| Name | Command |
|------|---------|
| Status | ssh moses@dev-workspace-vm "tmux ls 2>/dev/null \|\| echo 'no sessions'" |
| Health | ssh moses@dev-workspace-vm "~/projects/dev-workspace/scripts/dws-health.sh" |
| Kill all | ssh moses@dev-workspace-vm "tmux kill-server" |

## Tips

- Use **landscape mode** for Codex/Claude — the wider screen helps.
- Ctrl-a is the tmux prefix, not Ctrl-b (easier on phone keyboards).
- If the launcher doesn't appear, you may already be inside tmux. Press Ctrl-a d to detach first.
- To skip the launcher entirely: set SKIP_LAUNCHER=1 in Termius host environment variables.

## Mac Pubkey Repair

If Termius fails against the Mac even though the key is already in
`~/.ssh/authorized_keys`, run the repo helper on the Mac itself:

```bash
~/projects/dev-workspace/bin/dws-termius-mac-fix.sh
```

It prepends `PubkeyAuthentication yes` to `/etc/ssh/sshd_config`, forces
`~/.ssh` to `700`, forces `~/.ssh/authorized_keys` to `600`, removes
group/world write bits from the home directory, and validates the resulting
config with `sshd -t -f /etc/ssh/sshd_config`.

If the config check passes but the Mac is already running `sshd`, reload it:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```
