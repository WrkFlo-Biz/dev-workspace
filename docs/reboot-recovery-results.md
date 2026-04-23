# Reboot Recovery Drill — Results

Operator worksheet for recording a single dev-workspace-vm reboot recovery drill. Fill in every `<placeholder>` and check-slot during the drill. Leave this template untouched and create a filled copy at `~/reboot-drills/<YYYYMMDDTHHMMSSZ>/results.md` — do **not** commit filled-in runs back to this template.

Pair this worksheet with the plan at `docs/reboot-recovery-test.md`; section numbers match.

> **Status of this file:** template only. No drill has been executed against this doc.

## Test Metadata

| Field | Value |
|---|---|
| Drill ID | `<YYYYMMDDTHHMMSSZ, e.g. 20260424T030000Z>` |
| Operator | `<your name / handle>` |
| Trigger | `<scheduled / unplanned / post-change-validation / other>` |
| Change under test | `<commit SHA or "none" if pure drill>` |
| VM hostname / IP | `dev-workspace-vm / 100.117.16.63` |
| Coordinator notified | `<yes/no; channel>` |
| Start (UTC) | `<YYYY-MM-DDTHH:MM:SSZ>` |
| End   (UTC) | `<YYYY-MM-DDTHH:MM:SSZ>` |

## Phase 1 — Pre-reboot Snapshot

Baseline directory: `~/reboot-drills/<drill-id>/`

| File | Captured? | Notes |
|---|---|---|
| `timestamp.txt` | `[ ]` | |
| `uptime.before.txt` | `[ ]` | |
| `tmux.before.txt` | `[ ]` | session count: `<n>` |
| `user-services.before.txt` | `[ ]` | |
| `system-services.before.txt` | `[ ]` | tailscaled/ssh/ssh.socket/cron all `active`? `[ ]` |
| `cron.before.txt` | `[ ]` | `dev-workspace managed cron` entries: `<n>` (expect 3) |
| `tailscale.before.txt` | `[ ]` | peers visible: `<n>` |
| `health.before.json` | `[ ]` | `tailnet.connected`: `<bool>`, `tools.foundry_key_loaded`: `<bool>`, `services.dws_task_monitor.healthy/services.dws_sessions_init.healthy`: `<bool/bool>` |
| `task-queue.before.json` | `[ ]` | queue readable, tasks: `<n>` |

Pre-reboot readiness: `[ PASS / FAIL ]`

Notes: `<any anomalies before the reboot>`

## Phase 2 — Reboot Execution

| Step | Result |
|---|---|
| Reboot command issued | `sudo reboot` at `<HH:MM:SS UTC>` |
| SSH disconnected | `[ ]` at `<HH:MM:SS>` |
| VM reachable again (first successful `ssh ... uptime -p`) | at `<HH:MM:SS>` |
| Downtime (reachable − issued) | `<N seconds>` |
| Azure portal consulted? | `<no / yes — reason>` |

Execution result: `[ PASS / FAIL ]`  (fail = > 300 s unreachable or portal intervention required)

## Phase 3 — Post-reboot Verification

### 3.0 Automated smoke test

```bash
~/projects/dev-workspace/bin/dws-boot-verify.sh
```

- Total: `<pass>/<total>` passed, `<fail>` failed, `<warn>` warnings
- Final status line: `< STATUS: READY | STATUS: NEEDS ATTENTION >`
- Verdict: `[ PASS / FAIL ]`

### 3.1 Tailscale

```bash
systemctl is-active tailscaled
tailscale ip -4
tailscale status | head -10
```

| Check | Value | Pass |
|---|---|---|
| `tailscaled` active | `<active/inactive>` | `[ ]` |
| VM IP | `<100.x.x.x>` (expect `100.117.16.63`) | `[ ]` |
| Mac peer present (`100.78.207.22`) | `<yes/no>` | `[ ]` |
| openclaw-gateway peer present | `<yes/no>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.2 SSH (socket-activated)

```bash
systemctl is-active ssh ssh.socket sshd
ss -tlnp | grep :22
grep -E 'PasswordAuth|PermitRootLogin|X11Forwarding|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax' /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
```

| Check | Value | Pass |
|---|---|---|
| `ssh.service` active | `<active/inactive>` | `[ ]` |
| `ssh.socket` active | `<active/inactive>` | `[ ]` |
| `sshd` inactive (expected) | `<inactive/other>` | `[ ]` |
| Port 22 listening | `<yes/no>` | `[ ]` |
| PasswordAuthentication | `<no/other>` | `[ ]` |
| PermitRootLogin | `<no/other>` | `[ ]` |
| X11Forwarding | `<no/other>` | `[ ]` |
| MaxAuthTries | `<3/other>` | `[ ]` |
| ClientAliveInterval | `<30/other>` | `[ ]` |
| ClientAliveCountMax | `<3/other>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.3 dws-sessions-init.service

```bash
systemctl --user status dws-sessions-init.service --no-pager | head -15
journalctl --user -u dws-sessions-init.service -n 30 --no-pager
```

| Check | Value | Pass |
|---|---|---|
| Unit state | `<active (exited) / other>` | `[ ]` |
| Exit status | `<0/SUCCESS | other>` | `[ ]` |
| Log contains `sessions init complete: 10 sessions` | `<yes/no>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.4 dws-task-monitor.service

```bash
systemctl --user is-active dws-task-monitor.service
tail -n 20 /var/log/dws/monitor.log
```

| Check | Value | Pass |
|---|---|---|
| Unit active | `<active/inactive>` | `[ ]` |
| Log advancing (≥ 2 cycles since boot) | `<yes/no>` | `[ ]` |
| Timestamp of most recent cycle | `<HH:MM:SS>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.5 tmux sessions

```bash
tmux list-sessions
```

Expected managed set: `dws-a, dws-b, worker-c, worker-d, worker-e, worker-f, worker-g, worker-h, worker-i, orchestrator` (10 sessions). Extra ad hoc sessions may exist and should be noted separately.

| Session | Present | Codex running inside |
|---|---|---|
| `dws-a` | `[ ]` | `[ ]` |
| `dws-b` | `[ ]` | `[ ]` |
| `worker-c` | `[ ]` | `[ ]` |
| `worker-d` | `[ ]` | `[ ]` |
| `worker-e` | `[ ]` | `[ ]` |
| `worker-f` | `[ ]` | `[ ]` |
| `worker-g` | `[ ]` | `[ ]` |
| `worker-h` | `[ ]` | `[ ]` |
| `worker-i` | `[ ]` | `[ ]` |
| `orchestrator` | `[ ]` | `[ ]` |

Session count: `<n>/10`. Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.6 Launcher access

```bash
~/projects/dev-workspace/scripts/dws-launcher.sh status
```

| Check | Value | Pass |
|---|---|---|
| Exits 0 | `<yes/no>` | `[ ]` |
| Status header rendered | `<yes/no>` | `[ ]` |
| Active session count matches (§3.5) | `<yes/no>` | `[ ]` |
| Health summary present | `<yes/no>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.7 dws-phone-server.service

```bash
systemctl --user is-active dws-phone-server.service
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8081/health || true
```

| Check | Value | Pass |
|---|---|---|
| Unit active | `<active/inactive>` | `[ ]` |
| `/health` response | `<200/other>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.8 wrkflo-orchestrator-api.service

```bash
systemctl --user is-active wrkflo-orchestrator-api.service
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8100/v1/workspace/health
```

| Check | Value | Pass |
|---|---|---|
| Unit active | `<active/inactive>` | `[ ]` |
| `/v1/workspace/health` response | `<code>` (expect `200`) | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.9 Cron

```bash
systemctl is-active cron
crontab -l | grep -c "dev-workspace managed cron"
crontab -l | grep -E "dws-(health-check|log-rotate|session-cleanup)" | wc -l
```

| Check | Value | Pass |
|---|---|---|
| `cron.service` active | `<active/inactive>` | `[ ]` |
| Managed-block markers present | `<count>` (≥ 2) | `[ ]` |
| Dev-workspace entries count | `<n>` (expect 3) | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.10 Managed queue truth

```bash
jq -r '.tasks | length' ~/projects/dev-workspace/.state/task-queue.json
jq -r '.tasks[]? | select(.status=="in_progress") | [.id,.assigned,.repo] | @tsv' \
  ~/projects/dev-workspace/.state/task-queue.json
```

| Check | Value | Pass |
|---|---|---|
| Queue file readable, task count | `<n>` | `[ ]` |
| No orphaned `in_progress` tasks (worker missing from §3.5) | `<yes/no>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

### 3.11 Health / status commands

```bash
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
~/projects/dev-workspace/scripts/dws-health.sh --json
```

| Check | Value | Pass |
|---|---|---|
| `dws-status.sh` exits `0` | `<yes/no>` | `[ ]` |
| `dws-doctor.sh` exits `0` with no `FAIL` lines | `<yes/no>` | `[ ]` |
| `dws-health.sh --json` shows `tailnet.connected=true` | `<yes/no>` | `[ ]` |
| `dws-health.sh --json` shows both managed user services healthy | `<yes/no>` | `[ ]` |

Section verdict: `[ PASS / FAIL ]` — notes: `<…>`

## Phase 4 — Overall Verdict

- Sections passed: `<n>/11`
- Sections failed: `<n>`
- Warnings: `<n>`
- **Overall: `[ GREEN / AMBER / RED ]`**
  - GREEN = all sections PASS, 0 warnings
  - AMBER = all sections PASS, ≥ 1 warning, OR ≤ 1 non-blocking section FAIL with same-drill recovery
  - RED   = ≥ 1 unrecoverable FAIL, or VM required portal intervention

## Regressions Found

Note anything that passed the previous drill (or baseline) and failed this time.

| Section | Description | Introduced by (commit/change) | Severity |
|---|---|---|---|
| `<§n>` | `<what changed>` | `<sha or "unknown">` | `< low / med / high / blocking >` |

If no regressions: `none`.

## Fixes Applied During Drill

Ad-hoc recovery actions taken to reach GREEN/AMBER. Anything listed here should become a follow-up action (below) so the next drill doesn't need it.

| Time | Command / action | Effect |
|---|---|---|
| `<HH:MM>` | `<cmd>` | `<result>` |

If none: `none`.

## Follow-up Actions

One row per item that must be done before the next drill. Link to tickets/commits as they land.

| # | Action | Owner | Ticket / commit | Done by (next drill date) |
|---|---|---|---|---|
| 1 | `<e.g. add curl /health to dws-boot-verify.sh>` | `<name>` | `<link>` | `<date>` |
| 2 | `<…>` | | | |

## Sign-off

- Operator: `<name>` — `<signature/initials>`
- Reviewed by: `<name>` — `<signature/initials>`
- Artifacts stored at: `~/reboot-drills/<drill-id>/` — `[ uploaded / archived / n/a ]`
- Coordination file updated (`/tmp/task-coordination.md`) with drill completion: `[ ]`

## References

- Plan: `docs/reboot-recovery-test.md`
- Runbook: `docs/runbook.md`
- Automated smoke test: `~/projects/dev-workspace/bin/dws-boot-verify.sh`
- Risk register: `docs/risk-register-dev-workspace.md`
