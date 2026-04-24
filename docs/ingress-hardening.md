# Ingress Hardening

This document records the live ingress posture of the dev-workspace VM as
audited on 2026-04-23.

The intended primary ingress control is the tailnet policy: Tailscale ACLs gate
who can reach the VM over its Tailscale addresses. On the VM itself, host-level
firewall enforcement is currently minimal:

- `ufw` is installed but inactive.
- The only active kernel filter rules are the Tailscale-managed `ts-input` and
  `ts-forward` chains.
- `sshd` is hardened through
  `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf`.

## Current Control Layers

| Layer | Current state | Practical effect |
| --- | --- | --- |
| Tailscale ACLs | Primary intended ingress control | Access to the Tailscale IPs is governed by tailnet policy, not by this repo. |
| Tailscale host rules | Active `ts-input` / `ts-forward` chains | Accepts traffic arriving on `tailscale0`, accepts `udp/41641`, and drops spoofed `100.64.0.0/10` traffic that does not arrive via `tailscale0`. |
| UFW | Installed, but `sudo ufw status verbose` returns `Status: inactive` | No UFW policy is currently filtering inbound traffic. The `ufw.service` unit being enabled only means the unit ran at boot; it does not mean UFW is enforcing rules right now. |
| nftables / iptables base policy | `INPUT` policy is `ACCEPT` and the only explicit `INPUT` rule is a jump to `ts-input` | Services bound to `0.0.0.0` or `[::]` are not restricted by a host firewall deny policy. Any restriction beyond Tailscale must come from the application itself or an upstream network perimeter. |
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

This means SSH is hardened at the authentication layer even though it is not
currently narrowed by UFW.

## Open Ports

### Ingress-relevant listeners

| Bind | Proto | Process | Why it is open | Exposure notes |
| --- | --- | --- | --- | --- |
| `0.0.0.0:22`, `[::]:22` | TCP | `sshd` | Remote shell access for operators | Bound on all interfaces. Host firewall does not currently narrow this to Tailscale-only traffic, so access control relies on SSH hardening plus any upstream network perimeter. |
| `0.0.0.0:8081` | TCP | `dws-phone-server.service` (`~/bin/dws-phone-server.py`) | Phone-control callback server used by the iPhone shortcut flow (`/health`, `/pending`, `/queue`, `/result`) | Bound on all interfaces. The application comment says Tailscale ACLs are the intended gate, but the host firewall does not currently enforce that posture. |
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

- It does not deny public ingress by default.
- It does not restrict `22/tcp` to the Tailscale interface.
- It does not restrict `8081/tcp` to the Tailscale interface.

Operationally, that means Tailscale ACLs are the primary intended ingress
control, but the VM is not currently enforcing a Tailscale-only posture with a
host firewall.

## Audit Commands

These commands were used to verify the current posture:

```bash
sudo ufw status verbose
sudo iptables -S
sudo nft list chain ip filter INPUT
sudo nft list chain ip filter ts-input
sudo ss -tulpn
sed -n '1,160p' /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
systemctl --user status dws-phone-server.service --no-pager -l
sudo tailscale status --json
```
