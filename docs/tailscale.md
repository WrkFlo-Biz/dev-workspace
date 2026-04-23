# Tailscale mesh

A Tailscale tailnet is what makes this workspace "24/7 reachable from anywhere".
Every device joins one private mesh network and gets a stable `100.x.y.z` IP plus
a MagicDNS name like `dev-workspace-vm.<tailnet>.ts.net`.

## Nodes in this tailnet

| Node                | Role                                 | Auth owner       |
|---------------------|--------------------------------------|------------------|
| `dev-workspace-vm`  | Azure dev VM (codex + claude)        | `moses@wrkflo.biz` |
| `<mac-hostname>`    | This Mac                              | `moses@wrkflo.biz` |
| Phone (iOS)         | Tailscale app + Termius               | `moses@wrkflo.biz` |

## Setup each device

### VM (already done)

```bash
ssh moses@20.230.203.79
sudo tailscale up --ssh --operator=moses --hostname=dev-workspace-vm
# click the URL that gets printed, log in with @wrkflo.biz
```

The `--ssh` flag turns on [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)
so Termius can SSH without needing to manage SSH keys at all (optional — the
existing key-based auth still works).

### Mac

```bash
./mac-setup/bootstrap.sh   # installs Tailscale.app + enables sharing services
open -a Tailscale           # log in via the menu bar
```

### iPhone (Termius)

1. Install Tailscale from the App Store, log in with the same Google account.
2. In Termius, add two hosts:
   - **VM**: host `dev-workspace-vm` (MagicDNS) or `100.x.y.z` (Tailscale IP);
     user `moses`; key `termius_20260415`.
   - **Mac**: host `<mac-hostname>` (MagicDNS); user `mosestut`;
     key `termius_20260415` (after running `authorize-vm.sh` so that key works on Mac too).
3. Optional: Termius "Startup command" on VM host →
   `cd ~/global-sentinel && exec codex --profile foundry`

## Troubleshooting

- **Node missing from MagicDNS**: `tailscale status` on the source; if the node
  is listed but no DNS, run `tailscale up --accept-dns=true` on the client.
- **Mac sleeps and drops off the mesh**: open Tailscale → Preferences →
  enable "Run in Background" and disable "Connect on Demand". Also set
  `caffeinate -dimsu &` in a login item if the Mac must stay awake.
- **VM reboots and Tailscale is down**: systemd unit `tailscaled.service` is
  enabled, so it should come back. `sudo systemctl status tailscaled` if not.
