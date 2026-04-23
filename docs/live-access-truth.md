# Live Access Truth

Observed on `dev-workspace-vm` on 2026-04-23 UTC.

This file records the pre-hardening access state that was actually verified on
the VM, rather than the older assumptions in repo docs and task text.

## SSH runtime truth

- The VM is **not** using `sshd.service`.
- It is using Ubuntu's socket-activated OpenSSH layout:
  - `ssh.socket` is `enabled` and `active`
  - `ssh.service` is `active`
  - `sshd.service` and `sshd.socket` are not present
- This explains why `systemctl is-active sshd` can report `inactive` or
  `not-found` while SSH itself is working normally.

Verified with:

```bash
systemctl list-unit-files 'ssh*' 'sshd*' --no-pager
systemctl is-active ssh ssh.socket sshd sshd.socket
systemctl status ssh --no-pager -l
systemctl status ssh.socket --no-pager -l
```

## Effective SSH posture before hardening

Current config sources:

- `/etc/ssh/sshd_config`
- `/etc/ssh/sshd_config.d/50-cloud-init.conf`
- `/etc/ssh/sshd_config.d/50-cloudimg-settings.conf`
- `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`
- `/etc/ssh/sshd_config.d/99-wrkflo-hardening.conf`

Effective findings from those files:

- `PasswordAuthentication yes`
- `PermitRootLogin no`
- `PubkeyAuthentication yes`
- `KbdInteractiveAuthentication no`
- `ChallengeResponseAuthentication no`
- `ClientAliveInterval 120`
- `ClientAliveCountMax` not explicitly overridden from default

Why this matters:

- Password auth is still enabled on a VM that has a public SSH path.
- Server-side keepalive exists, but it is weaker than the target posture for a
  mobile/operator-heavy workflow.

## Authorized key truth

`~/.ssh/authorized_keys` contains duplicate entries.

Verified state:

- total non-comment key lines: `6`
- unique key lines: `5`
- one duplicated `ssh-ed25519` key appears on lines `5` and `6`

Verified with:

```bash
python3 - <<'PY'
from pathlib import Path
p=Path.home()/'.ssh'/'authorized_keys'
lines=p.read_text().splitlines()
seen={}
for i,line in enumerate(lines,1):
    s=line.strip()
    if not s or s.startswith('#'):
        continue
    seen.setdefault(s,[]).append(i)
for key,locs in seen.items():
    if len(locs)>1:
        print(locs, key[:120])
print("total_keys", sum(1 for l in lines if l.strip() and not l.strip().startswith('#')))
print("unique_keys", len(seen))
PY
```

## Listening services and exposure

Observed listening ports on the VM:

| Listener | Bind | Purpose | Exposure truth |
| --- | --- | --- | --- |
| `22/tcp` | `0.0.0.0`, `[::]` | OpenSSH | internet-reachable via Azure NSG |
| `8081/tcp` | `0.0.0.0` | `dws-phone-server` | not explicitly allowed by Azure NSG, but open on-host |
| `8100/tcp` | `127.0.0.1` | orchestrator health/API | loopback-only |
| `41641/udp` | `0.0.0.0`, `[::]` | Tailscale | expected |

Key nuance:

- The VM has a host-level listener on `0.0.0.0:8081`.
- The Azure NSG currently has only one explicit inbound allow rule, `22/tcp`.
- So `8081` is not publicly exposed through Azure today, but it is also not
  protected by an operator-managed host firewall policy.

Verified with:

```bash
ss -tulpn
az network nsg show -g dev-ws-westus2 -n dev-workspace-vmNSG -o yaml
az network public-ip show -g dev-ws-westus2 -n dev-workspace-vmPublicIP -o yaml
```

## Azure public ingress truth

Current Azure ingress state:

- Resource group: `dev-ws-westus2`
- Public IP: `20.230.203.79`
- NSG: `dev-workspace-vmNSG`
- Explicit inbound allow rule:
  - `default-allow-ssh`
  - direction: `Inbound`
  - access: `Allow`
  - protocol: `Tcp`
  - source: `*`
  - destination port: `22`
  - priority: `1000`

This means the VM is publicly reachable on `22/tcp` from anywhere on the
internet today.

## Firewall truth

Operator-managed firewall posture is currently absent:

- `ufw` status: `inactive`
- There is no custom `ufw` policy enforcing Tailscale-first access.
- There is no operator-created deny-by-default host policy.

But the box is not rule-free:

- Tailscale has already installed its own `iptables` / `nftables` chains
  (`ts-input`, `ts-forward`) for tailnet traffic handling.

Implication:

- "No firewall" is only partly true.
- The accurate statement is: **no operator-managed ingress hardening exists yet;
  only Tailscale-managed chains are present**.

## Real SSH access evidence

SSH journal evidence on 2026-04-23 shows:

- successful public-key logins from the Mac Tailscale IP `100.78.207.22`
- successful public-key logins from the iPhone Tailscale IP `100.88.249.22`
- at least one successful public-key login from public IP `72.24.145.11`
- repeated failed password attempts from internet scanners against `root`,
  `oracle`, `debian`, `test`, `testuser`, and `sonar`

This is the strongest current access-risk signal:

- password auth is still enabled
- the public Azure SSH path is open
- internet password sprays are already hitting the VM

Verified with:

```bash
journalctl -u ssh --since 'today' --no-pager | rg 'Accepted publickey|Accepted password|Failed password'
journalctl -u ssh --since '7 days ago' --no-pager | rg '100\.88\.249\.22|iphone-15-pro-max'
```

## Phone / Termius truth

The phone path is not merely theoretical.

Verified evidence:

- SSH journal contains successful public-key logins from `100.88.249.22`
- this proves iPhone -> Tailscale -> VM -> SSH key auth worked on the live box

What is still missing:

- a formal operator test record for launcher usability, `tmux` reattach, and
  day-two phone recovery flow

## Immediate hardening implications

Highest-priority corrections implied by the live truth:

1. Disable `PasswordAuthentication`
2. Keep `PermitRootLogin no`
3. Tighten server-side keepalive to the operator standard
4. Clean duplicate `authorized_keys`
5. Add operator-managed ingress policy without breaking Tailscale

## Verification commands

```bash
systemctl list-unit-files 'ssh*' 'sshd*' --no-pager
systemctl is-active ssh ssh.socket sshd sshd.socket
sudo -n sh -c 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -e "$f" ] || continue; echo "--- $f ---"; sed -n "1,200p" "$f"; done'
ss -tulpn
sudo -n ufw status verbose
sudo -n iptables -S
sudo -n nft list ruleset
journalctl -u ssh --since 'today' --no-pager | rg 'Accepted publickey|Failed password'
journalctl -u ssh --since '7 days ago' --no-pager | rg '100\\.88\\.249\\.22'
az network nsg show -g dev-ws-westus2 -n dev-workspace-vmNSG -o yaml
az network public-ip show -g dev-ws-westus2 -n dev-workspace-vmPublicIP -o yaml
```
