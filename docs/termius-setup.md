# Termius Setup

Use [`bin/dws-termius-setup.sh`](../bin/dws-termius-setup.sh) whenever you need
the current host values or the recommended SSH key path:

```bash
~/projects/dev-workspace/bin/dws-termius-setup.sh
```

Use the helper output as the source of truth for the current VM settings:

- Hostname: the helper-reported current host value. If you are entering it
  manually, prefer `dev-workspace-vm` when MagicDNS is working; otherwise use
  the current Tailscale IP it reports.
- Port: `22`
- Username: `moses`
- Authentication: SSH key
- SSH key path: `DWS_TERMIUS_KEY_PATH` when set, otherwise the first existing
  key from `~/.ssh/termius_20260415`, `~/.ssh/id_ed25519`, and `~/.ssh/id_rsa`

## Before you start

1. Install and sign in to Tailscale on the device that will run Termius.
2. Join the same tailnet as `dev-workspace-vm`.
3. Run `bin/dws-termius-setup.sh` on a machine that already has the private key.
4. If you are setting up iPhone Termius, securely copy that same private key to
   the phone with AirDrop, iCloud Drive, or Files so Termius can import it.

## Desktop Termius

1. Open Termius and create a new host.
2. Set **Label** to `Dev Workspace VM`.
3. Set **Address / Hostname** to `dev-workspace-vm` or the current Tailscale
   IP reported by `bin/dws-termius-setup.sh`.
4. Set **Port** to `22`.
5. Set **Username** to `moses`.
6. Set **Authentication** to **Key**.
7. Add or select the private key shown by `bin/dws-termius-setup.sh`.
8. In the host terminal settings, use:
   - **Mosh**: Off
   - **SSH agent forwarding**: Off
   - **Startup command**: leave blank
   - **Keepalive interval**: 30 seconds
   - **Terminal type**: `xterm-256color`
   - **Character encoding**: `UTF-8`
   - **Local echo**: Off
9. Save the host and connect.
10. After login, let the workspace launcher start normally. Inside tmux, the
    prefix is `Ctrl-a`.

## iPhone Termius

1. Install Tailscale and Termius from the App Store.
2. Sign in to Tailscale with the same account used by the VM.
3. Run `bin/dws-termius-setup.sh` on a Mac or desktop that already has the SSH
   key, then note the reported key path.
4. Copy that private key to the iPhone with AirDrop, iCloud Drive, or Files.
5. In Termius, open **Keys**, tap **+**, then import the private key file.
6. Open **Hosts**, tap **+**, then create a new host with:
   - **Label**: `Dev Workspace VM`
   - **Address / Hostname**: `dev-workspace-vm` or the current Tailscale IP
     reported by `bin/dws-termius-setup.sh`
   - **Port**: `22`
   - **Username**: `moses`
   - **Authentication**: the imported SSH key
7. In the host terminal settings, use:
   - **Mosh**: Off
   - **SSH agent forwarding**: Off
   - **Startup command**: leave blank
   - **Keepalive interval**: 30 seconds
   - **Terminal type**: `xterm-256color`
   - **Character encoding**: `UTF-8`
   - **Local echo**: Off
8. Save and connect.
9. On the first successful login, the dev-workspace launcher should open. Use
   landscape mode when you are actively working in Codex or Claude.
10. To leave a session running, detach from tmux with `Ctrl-a d` before closing
    the SSH connection.

## Notes

- If the helper reports the SSH key path as `missing`, either point
  `DWS_TERMIUS_KEY_PATH` at the correct private key and rerun it, or use
  Tailscale SSH instead of key-based authentication.
- Leave the startup command blank unless you intentionally want to bypass the
  launcher.
