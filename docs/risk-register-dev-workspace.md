# Risk Register: dev-workspace

Captured on 2026-04-23 UTC from the live VM state.

## Critical

| Risk | Evidence | Impact | Immediate action |
| --- | --- | --- | --- |
| Public SSH with password auth still enabled | Azure NSG allows `22/tcp` from `*`; SSH logs show internet password spraying; `PasswordAuthentication yes` is still active | brute-force exposure on the primary operator VM | disable password auth safely, keep key auth intact, validate before reload |
| No operator-managed host ingress policy | `ufw` inactive; only Tailscale-managed nft/iptables chains exist | accidental future exposure if Azure NSG or local listeners widen | install a Tailscale-first firewall posture that preserves SSH and tailnet traffic |
| Repo / live runtime drift | live `~/bin/dws-sessions-init.sh` and `~/bin/dws-boot-verify.sh` do not match the checked-in repo copies; docs and operator commands can disagree depending on which path is used | operators can run the wrong recovery path or validate the wrong behavior during incidents | redeploy the host-managed `~/bin` helpers or explicitly document repo vs live surfaces and prefer service state for truth |

## High

| Risk | Evidence | Impact | Immediate action |
| --- | --- | --- | --- |
| Duplicate `authorized_keys` entries | duplicate key lines in `~/.ssh/authorized_keys` | unclear access state, harder rollback/audit | dedupe while preserving Mac and phone keys |
| Script-surface drift between `bin/` and `scripts/` | `cleanup`, `cron-setup`, and `sessions` have overlapping or legacy implementations | operator confusion and inconsistent automation behavior | define one canonical CLI surface and convert legacy paths to wrappers |
| No reboot-recovery proof | no documented or executed reboot drill yet | "self-healing" claims remain unverified | run a structured reboot recovery test and record results |
| Runtime state is split across `/var/log/dws`, `.state/`, and `/tmp` defaults | live monitor uses `/var/log/dws/monitor.log` and `~/projects/dev-workspace/.state/task-queue.json`, while `dws-status.sh`/`dws-doctor.sh` still default to legacy `/tmp/*` artifacts | triage can point operators at stale files or mixed signals | align the scripts with the live service model and document the authoritative surfaces clearly |

## Medium

| Risk | Evidence | Impact | Immediate action |
| --- | --- | --- | --- |
| Phone path lacks a formal verification artifact | iPhone SSH success exists in journal, but there is no structured operator test record | docs can drift from real operator behavior | run and document a real phone validation checklist |
| `dws-phone-server` binds `0.0.0.0:8081` | service is reachable on-host and via tailnet; Azure NSG currently blocks public ingress | future ingress mistakes could expose phone callback path | document intended exposure and include in firewall policy review |
| Repo is busy and dirty | many modified/untracked files; active worker sessions still editing repo-owned files | commit conflicts and accidental reverts | avoid worker-owned files, stage changes in coherent batches only after workers settle |
| Ad hoc `tmux` sessions can blur the managed baseline | managed boot set is 9 sessions, but extra sessions such as `worker-i` can appear during live work | operators may misread a healthy runtime as drift, or miss real boot regressions | treat the 9-session pool as the managed contract and anything extra as opt-in/operator-owned |

## Low

| Risk | Evidence | Impact | Immediate action |
| --- | --- | --- | --- |
| Multiple status surfaces overlap | `dws-status`, `dws-motd`, `dws-health`, `dws-health-full` all present | duplicated maintenance effort | clarify ownership while consolidating script layout |

## Current change constraints

Files and surfaces that should be treated as conflict-sensitive while active
workers are running:

- `scripts/dws-launcher.sh`
- `bin/dws-backup.sh`
- `bin/dws-cleanup.sh`
- `bin/dws-doctor.sh`
- `bin/dws-sync-mac.sh`
- `scripts/dws-cleanup.sh`
- `scripts/dws-doctor.sh`
- `scripts/dws-health.sh`
- `scripts/dws-health-check.sh`
- `scripts/dws-quick.sh`
- `scripts/vm-bootstrap.sh`
- `.orchestrator/*`

Safer immediate work areas:

- new docs under `docs/`
- new service units or support files that do not collide with active worker edits
- focused SSH/firewall config changes outside the repo, recorded by docs and
  later codified in setup scripts once the worker batch settles

## Verification commands

```bash
systemctl is-active ssh ssh.socket
sudo -n sh -c 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -e "$f" ] || continue; echo "--- $f ---"; sed -n "1,120p" "$f"; done'
journalctl -u ssh --since 'today' --no-pager | rg 'Accepted publickey|Failed password'
sudo -n ufw status verbose
sudo -n iptables -S
tmux list-sessions
systemctl --user list-unit-files --no-pager | rg 'dws|wrkflo|monitor|task'
tail -n 40 /var/log/dws/monitor.log
sed -n '1,120p' ~/projects/dev-workspace/.state/task-queue.json
git status --short --branch
```
