# Ingress Hardening

`bin/dws-firewall.sh` is the repo-managed ingress policy for the dev workspace VM.
The default action now does three things in order:

1. Snapshot the current firewall state for rollback.
2. Apply the repo policy.
3. Verify the live rules and roll back automatically if verification fails.

## Managed Ingress Policy

The repo policy is intentionally small:

| Port / proto | Source | Purpose |
| --- | --- | --- |
| `41641/udp` | anywhere | Tailscale peer traffic and NAT traversal |
| `22/tcp` | `100.64.0.0/10` | SSH over Tailscale |
| `8080/tcp` | `100.64.0.0/10` | repo-managed dev service |
| `9222/tcp` | `100.64.0.0/10` | Chrome remote debugging |
| `3000/tcp` | `100.64.0.0/10` | repo-managed dev service |

Everything else inbound is denied.

For `iptables`, the repo-managed chain also keeps loopback and
`RELATED,ESTABLISHED` traffic open before the final drop rule.

## Dry Run

Preview the exact commands without changing the host:

```bash
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run --backend ufw
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run --backend iptables
```

Dry-run output includes:

- the backend that would be used
- the Tailscale note explaining why `udp/41641` stays public
- the rollback snapshot path that would be created
- every firewall command that would run

Use dry-run first if you are changing hosts, testing a new backend, or working
over a remote session you cannot afford to lock out.

## Apply

Apply the policy with root privileges:

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend iptables
```

Apply behavior:

- prefers `ufw` when it is installed unless `--backend` is set
- saves a rollback snapshot before changing anything
- verifies the live rules immediately after apply
- rolls back automatically if the apply or verification step fails

## Verification

Run the read-only verifier at any time:

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify --backend ufw
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify --backend iptables
```

Verification checks:

- `ufw` is active and defaults to `deny (incoming), allow (outgoing)`
- `udp/41641` is still open globally
- `tcp/22`, `tcp/8080`, `tcp/9222`, and `tcp/3000` are restricted to `100.64.0.0/10`
- no public allow rule exists for the managed TCP ports
- for `iptables`, `DWS_FIREWALL_INPUT` is the first `INPUT` rule and ends with `DROP`

`--verify` exits non-zero on drift or overly broad access.

## Rollback

Rollback restores the most recent saved snapshot:

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback --backend ufw
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback --backend iptables
```

Rollback behavior:

- `ufw`: restores the saved config files and re-enables or disables `ufw` to
  match the captured state
- `iptables`: restores the full `iptables-save` snapshot with `iptables-restore`

After rollback, rerun `--verify` only if you intend to be back on the repo
policy. A rollback may intentionally restore a broader pre-repo firewall state.

## Snapshot Layout

Rollback snapshots are stored under `/var/lib/dws/firewall` by default. Override
that location with `DWS_FIREWALL_STATE_DIR=/path/to/state-dir`.

The script writes:

- `latest` -> newest snapshot for any backend
- `latest-ufw` -> newest UFW snapshot
- `latest-iptables` -> newest iptables snapshot
- `snapshots/<timestamp>-<backend>/...` -> snapshot payload

Snapshot contents:

- UFW snapshots include backend metadata plus the managed UFW config files:
  `/etc/default/ufw`, `/etc/ufw/ufw.conf`, `/etc/ufw/user.rules`,
  `/etc/ufw/user6.rules`
- iptables snapshots include a full `iptables-save` dump for restore

## Recommended Workflow

1. `~/projects/dev-workspace/bin/dws-firewall.sh --dry-run`
2. `sudo ~/projects/dev-workspace/bin/dws-firewall.sh`
3. `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify`
4. If access is wrong, `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback`
