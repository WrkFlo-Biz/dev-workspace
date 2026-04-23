# Ingress Hardening

`bin/dws-firewall.sh` is the repo entrypoint for the VM's inbound firewall
policy. It applies a narrow Tailscale-first profile, supports dry-run review,
captures rollback snapshots before changes, and can verify or restore the last
saved state.

## Policy

The intended inbound policy is:

- allow `udp/41641` from anywhere for Tailscale peer traffic
- allow `tcp/22` only from `100.64.0.0/10`
- allow `tcp/8080`, `tcp/9222`, and `tcp/3000` only from `100.64.0.0/10`
- deny all other inbound traffic

The subnet allowlist defaults to the Tailscale CGNAT range
`100.64.0.0/10`. Override it with `DWS_TAILSCALE_SUBNET` only if the tailnet
design changes.

## Backends

The script prefers `ufw` when present and falls back to `iptables`.

- `ufw`: resets UFW, sets `deny incoming` and `allow outgoing`, installs the
  explicit allow rules, then enables UFW.
- `iptables`: manages a dedicated `DWS_FIREWALL_INPUT` chain, inserts a single
  jump from `INPUT`, allows loopback plus `RELATED,ESTABLISHED`, adds the
  Tailscale rules, then drops all other inbound IPv4 traffic at the end of the
  chain.

## Dry Run

Review the exact commands before touching the live firewall:

```bash
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run --backend ufw
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run --backend iptables
```

Dry-run prints the commands it would execute and the snapshot directory it
would create, but it does not change firewall state.

## Apply

Apply the repo policy on the VM:

```bash
~/projects/dev-workspace/bin/dws-firewall.sh
```

The script escalates with `sudo` if needed, saves a rollback snapshot under
`/var/lib/dws/firewall` by default, applies the selected backend, then runs
built-in verification.

The snapshot root can be overridden with `DWS_FIREWALL_STATE_DIR`.

## Verify

Re-check the active firewall state without changing it:

```bash
~/projects/dev-workspace/bin/dws-firewall.sh --verify
~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --verify
~/projects/dev-workspace/bin/dws-firewall.sh --backend iptables --verify
```

Verification checks:

- backend is active and readable
- `udp/41641` remains globally reachable
- `tcp/22`, `tcp/8080`, `tcp/9222`, and `tcp/3000` are restricted to
  `100.64.0.0/10`
- no unexpected public TCP allow rules exist for those ports
- the final deny/drop behavior is present

## Rollback

Restore the most recent saved snapshot:

```bash
~/projects/dev-workspace/bin/dws-firewall.sh --rollback
```

Snapshots are tracked under:

```text
/var/lib/dws/firewall/
  latest
  latest-ufw
  latest-iptables
  snapshots/<timestamp>-<backend>/
```

Rollback behavior:

- `ufw`: restores captured UFW config files and returns UFW to its prior active
  or inactive state
- `iptables`: restores the saved ruleset with `iptables-restore`, then persists
  it when the host supports persistence

If an apply step fails after a snapshot is created, the script attempts an
automatic rollback from that snapshot before exiting.

## Quick Checks

Use these host-level checks after a successful apply:

```bash
~/projects/dev-workspace/bin/dws-firewall.sh --verify
sudo ufw status verbose
sudo iptables -w -S INPUT
sudo iptables -w -S DWS_FIREWALL_INPUT
```

For a remote validation from another Tailscale node, confirm:

- SSH still works over the tailnet
- the expected dev ports are reachable from a Tailscale peer
- the same TCP ports are not reachable from outside the tailnet

## Operational Notes

- Keep `udp/41641` public. Tailscale direct peer traffic depends on it.
- Do not broaden the SSH or dev-port rules beyond `100.64.0.0/10` unless the
  access model has changed intentionally.
- Prefer `--dry-run` before changes on a remotely accessed VM.
- Treat `/var/lib/dws/firewall` as rollback state that should remain on-host.
