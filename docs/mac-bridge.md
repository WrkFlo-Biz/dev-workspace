# Mac bridge

How the Mac is wired into the mesh so the VM (and your phone) can reach it.

## Services enabled

`mac-setup/bootstrap.sh` turns these on:

| Service            | How                                                     | Used by                         |
|--------------------|---------------------------------------------------------|---------------------------------|
| Remote Login (SSH) | `sudo systemsetup -setremotelogin on`                   | Termius, VM rsync               |
| Remote Management  | `kickstart -activate ... -privs -all`                   | VNC from iPad/laptop, ARD tools |
| File Sharing (SMB) | `launchctl load com.apple.smbd`                         | Finder mounts from iPad         |
| Tailscale.app      | `brew install --cask tailscale-app`                     | Mesh membership                 |

"Remote Management" is the superset — it includes Screen Sharing plus admin
capabilities (scripts, installs, restart). You approved full/unlimited access.

## Reaching the Mac

After `Tailscale.app` is logged in:

```bash
tailscale status   # find the Mac's 100.x.y.z IP and MagicDNS name

# From VM or phone:
ssh mosestut@<mac-magicdns>       # terminal
open vnc://<mac-magicdns>         # screen share (iPad VNC client, not Termius)
smb://<mac-magicdns>              # Finder/Files mount
```

## VM → Mac passwordless SSH

`mac-setup/authorize-vm.sh` grabs the VM's `~/.ssh/id_ed25519.pub` and appends it
to `~/.ssh/authorized_keys` on the Mac. After that, codex on the VM can:

```bash
# From the VM session:
ssh mosestut@<mac-magicdns> 'ls ~/some-repo'
rsync -avz ~/work/ mosestut@<mac-magicdns>:/Users/mosestut/work/
```

## Keeping the Mac awake

The Mac drops off the mesh when it sleeps. Three options:

1. **Least invasive**: System Settings → Battery → "Prevent automatic sleeping
   when display is off" (desktop) or "Wake for network access" (laptop on power).
2. **Always on**: `caffeinate -dimsu &` in a login item or LaunchAgent.
3. **If you want to be aggressive**: `sudo pmset -a disablesleep 1`
   (this is a heavy hammer; reverse with `disablesleep 0`).

Tailscale has no "Wake on LAN" on macOS, so a sleeping Mac is unreachable.

## Security notes

- SSH and ARD are exposed only on the Tailscale interface once you're set up.
  The Tailscale ACL defaults restrict all traffic to devices on your tailnet.
- If you want to ALSO accept SSH from the public internet, keep the default
  (port 22 open). Otherwise, add an ACL rule in the Tailscale admin console.
- ARD password is your macOS login password. Rotate via
  System Settings → General → Sharing → Remote Management → Options.
