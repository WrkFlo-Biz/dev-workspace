# Ingress Hardening

This document records the live ingress posture of the dev-workspace VM as
audited on 2026-04-24.

The intended primary ingress control is the tailnet policy: Tailscale ACLs gate
who can reach the VM over its Tailscale addresses. Operationally, SSH access is
now Tailscale-only: `tcp/22` is limited to `100.64.0.0/10`, and there is no
public internet SSH access. On the VM itself, host-level filtering is still
most visible through the Tailscale-managed chains:

- `bin/dws-firewall.sh` exists, but neither `ufw` nor `iptables` is currently
  installed on this VM, so the repo-managed host firewall policy has not been
  applied.
- Effective SSH restriction currently comes from the combined Tailscale /
  upstream ingress path rather than from a repo-managed `ufw` or `iptables`
  backend on this VM.
- The only active kernel filter rules are the Tailscale-managed `ts-input` and
  `ts-forward` chains.
- `sshd` is hardened through
  `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf`.

## Current Control Layers

| Layer | Current state | Practical effect |
| --- | --- | --- |
| Tailscale ACLs | Primary intended ingress control | Access to the Tailscale IPs is governed by tailnet policy, not by this repo. |
| Tailscale host rules | Active `ts-input` / `ts-forward` chains | Accepts traffic arriving on `tailscale0`, accepts `udp/41641`, and drops spoofed `100.64.0.0/10` traffic that does not arrive via `tailscale0`. |
| SSH exposure | `tcp/22` restricted to `100.64.0.0/10` | Operator SSH access is Tailscale-only; there is no public internet SSH path. |
| Repo firewall backend availability | `bin/dws-firewall.sh` is present, but `command -v ufw` and `command -v iptables` both fail on this VM | The repo-managed firewall policy cannot be applied until one supported backend is installed. |
| nftables / iptables base policy | `INPUT` policy is `ACCEPT` and the only explicit `INPUT` rule is a jump to `ts-input` | There is no blanket host-level default deny for every wildcard listener. SSH is the exception in the current posture; other services may still rely on application controls or an upstream perimeter. |
| SSH daemon hardening | `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf` | Disables password and keyboard-interactive auth, disables root login, requires pubkeys, and sets client keepalives. |

## SSH Hardening

The live SSH drop-in currently sets:

| Setting | Value |
| --- | --- |
| `PasswordAuthentication` | `no` |
| `KbdInteractiveAuthentication` | `no` |
| `ChallengeResponseAuthentication` | `no` |
| `PubkeyAuthentication` | `yes` |
| `PermitRootLogin` | `no` |
| `ClientAliveInterval` | `30` |
| `ClientAliveCountMax` | `3` |

This means SSH is hardened at the authentication layer and, in the current
posture, is reachable only from Tailscale peers in `100.64.0.0/10`. There is
no public internet SSH access.

## Open Ports

### Ingress-relevant listeners

| Bind | Proto | Process | Why it is open | Exposure notes |
| --- | --- | --- | --- | --- |
| `0.0.0.0:22`, `[::]:22` | TCP | `sshd` | Remote shell access for operators | Bound on all interfaces, but effective access is limited to `100.64.0.0/10` / Tailscale-only sources. There is no public internet SSH access. |
| `0.0.0.0:8081` | TCP | host-local `dws-phone-server.service` (`~/bin/dws-phone-server.py`) | Phone-control callback server used by the iPhone shortcut flow (`/health`, `/pending`, `/queue`, `/result`) | Bound on all interfaces. This repo does not provision the unit. The application comment says Tailscale ACLs are the intended gate, but the host firewall does not currently enforce that posture. |
| `0.0.0.0:41641`, `[::]:41641` | UDP | `tailscaled` | Tailscale WireGuard / magicsock listener for peer traffic and NAT traversal | Expected and required for Tailscale connectivity. This is the one globally accepted UDP port in the Tailscale-managed host rules. |
| `100.117.16.63:52421` | TCP | `tailscaled` | Tailscale PeerAPI on the node's Tailscale IPv4 address | Bound only to the Tailscale IPv4 address, not to a wildcard interface. |
| `[fd7a:115c:a1e0::cf37:103f]:38251` | TCP | `tailscaled` | Tailscale PeerAPI on the node's Tailscale IPv6 address | Bound only to the Tailscale IPv6 address, not to a wildcard interface. |

### Local-only or support listeners

These sockets exist on the host, but they are not intended as external ingress
surfaces.

| Bind | Proto | Process | Why it is open |
| --- | --- | --- | --- |
| `127.0.0.1:8100` | TCP | `wrkflo_orchestrator.cli api` | Local-only orchestrator API for VM-side tooling |
| `127.0.0.53:53`, `127.0.0.54:53` | TCP/UDP | `systemd-resolved` | Local DNS stub listeners |
| `127.0.0.1:323`, `[::1]:323` | UDP | `chronyd` | Loopback NTP control / monitoring socket |
| `10.0.0.4:68` | UDP | `systemd-networkd` | DHCP client socket on `eth0` |

## Effective Host Firewall Rules

The live packet filter is Tailscale-managed and intentionally narrow:

- `INPUT` policy is `ACCEPT`.
- `FORWARD` policy is `ACCEPT`.
- `INPUT` jumps to `ts-input`.
- `ts-input` accepts traffic on `tailscale0`.
- `ts-input` accepts `udp/41641`.
- `ts-input` drops spoofed `100.64.0.0/10` packets that arrive outside
  `tailscale0`.

What it does **not** currently do:

- It does not deny public ingress by default for every wildcard listener.
- It does not restrict `8081/tcp` to the Tailscale interface.

Operationally, SSH is now Tailscale-only, but the VM still does not enforce the
same blanket Tailscale-only posture for every wildcard listener with a general
host-firewall default deny.

## Repo Firewall Script Readiness

`bin/dws-firewall.sh` is a wrapper around `scripts/dws-firewall.sh`. The script
supports `--dry-run`, `--verify`, and `--rollback`, and the repo test suite
currently passes for both the `ufw` and `iptables` code paths
(`bash tests/test_dws_firewall.sh`).

Flag behavior:

- `--dry-run` prints the exact apply or rollback commands without changing the host
- `--verify` is read-only; for `iptables` it checks that `DWS_FIREWALL_INPUT`
  is the first `INPUT` jump and that the live managed chain still matches the
  repo policy in order
- `--rollback` restores the most recent pre-apply snapshot saved under
  `/var/lib/dws/firewall/`; combine it with `--dry-run` to preview the exact
  recovery steps before changing the host

The intended repo-managed policy is:

- default deny incoming, default allow outgoing
- allow `udp/41641` from anywhere for Tailscale peer traffic
- allow `tcp/22`, `tcp/8080`, `tcp/8081`, `tcp/9222`, and `tcp/3000` only from `100.64.0.0/10`
- deny all other inbound traffic

Important nuances:

- the script does **not** restrict `udp/41641` to `100.64.0.0/10`; it stays
  globally open so direct Tailscale peers and NAT traversal keep working
- the script keeps `tcp/22` Tailscale-only by restricting it to
  `100.64.0.0/10`; it is not intended to leave a public internet SSH path
- the local orchestrator API stays on `127.0.0.1:8100`; it is not part of the
  repo-managed Tailscale dev-port allowlist
- the SSH port and the repo-managed dev ports stay restricted to the Tailscale
  subnet at the host-firewall layer

Readiness findings from the 2026-04-24 review:

- `bin/dws-firewall.sh --dry-run --backend ufw` currently exits with
  `requested firewall backend is not installed: ufw`
- `bin/dws-firewall.sh --dry-run` currently exits with
  `neither ufw nor iptables is installed`
- because neither supported backend is installed, the script logic looks ready
  but the host is not yet ready to apply it safely

### Exact Apply Procedure

Do not enable the firewall from a single fragile session. Before the first real
apply, all of the following should be true:

1. Install one supported backend first. If the operational choice is UFW, make
   sure `command -v ufw` succeeds on the VM before relying on the wrapper.
2. Keep one Tailscale SSH session open and keep a second recovery path
   available, such as Azure serial console or a second shell.
3. Confirm Tailscale and SSH are already healthy before touching ingress:
   `tailscale status`, `systemctl is-active ssh ssh.socket`, and a live SSH
   login over the Tailscale path.
4. Preview the exact rules without changing the host:
   `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --dry-run`
5. Apply from the known-good session:
   `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw`
6. Verify immediately after apply:
   `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --verify`
7. Re-test SSH on `22/tcp`, plus the required dev ports from a Tailscale peer:
   SSH and the repo-managed dev ports should answer from `100.64.0.0/10`, and
   SSH should not be reachable from the public internet.
8. If verification fails or reachability regresses, restore immediately from
   the surviving session:
   `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --rollback`
9. Keep rollback available before closing the last surviving session.

The apply command automatically snapshots the pre-change backend state under
`/var/lib/dws/firewall/snapshots/<timestamp>-<backend>` and refreshes the
`latest` / `latest-<backend>` symlinks in `/var/lib/dws/firewall/`.

### Exact Rollback Procedure

If apply or verification leaves the host in the wrong state:

1. Preview the rollback actions first if you want a read-only check:
   `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --rollback --dry-run`
2. Restore the most recent saved snapshot:
   `sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw --rollback`
3. Confirm the host is back to the expected pre-apply state with backend-native
   inspection plus a real connectivity check. For example:
   `sudo ufw status verbose`
   `sudo iptables -S INPUT`
4. Re-test the surviving SSH session before closing it.

For `iptables`, swap `--backend ufw` for `--backend iptables`. Rollback restores
the saved backend snapshot rather than trying to compute an inverse rule set, so
`--verify` is only appropriate after a successful apply of the repo policy, not
after restoring an older snapshot that may intentionally differ.

## Audit Commands

These commands were used to verify the current posture:

```bash
sudo ufw status verbose
sudo iptables -S
sudo nft list chain ip filter INPUT
sudo nft list chain ip filter ts-input
sudo ss -tulpn
sed -n '1,160p' /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
systemctl --user status dws-phone-server.service --no-pager -l  # if the host-local phone server is installed
sudo tailscale status --json
```
