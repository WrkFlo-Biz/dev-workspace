# Reboot Recovery Test Plan

Operator drill for validating the `dev-workspace-vm` stack after a VM restart. Use this plan before any maintenance reboot, after unplanned outages, or on a cadence (quarterly) to confirm recovery posture.

This doc does not change runtime code — it tells you what to observe and in what order. The canonical post-reboot smoke test is `~/projects/dev-workspace/bin/dws-boot-verify.sh`; the sections below expand its coverage (phone server, orchestrator API, launcher, cron entries) and define explicit pass/fail criteria.

## Scope

The drill validates that after a clean reboot (`sudo reboot`), the following come back without manual intervention:

| Component | Mechanism | Expected state |
|---|---|---|
| Tailscale mesh | `tailscaled.service` (system) | active, VM IP `100.117.16.63`, Mac + iPhone visible |
| SSH | `ssh.socket` (socket-activated) | `ssh.socket` active, `ssh.service` starts on first connection |
| systemd user services | linger + `default.target.wants/` | 4 user services active |
| dws-sessions-init.service | `~/bin/dws-sessions-init.sh` (oneshot) | 9 tmux sessions recreated |
| dws-task-monitor.service | `~/bin/task-monitor.sh` (simple, Restart=on-failure) | active, writing `/var/log/dws/monitor.log` |
| dws-phone-server.service | `~/bin/dws-phone-server.py` | active, Restart=always |
| wrkflo-orchestrator-api.service | FastAPI on `127.0.0.1:8100` | active, `/v1/workspace/health` returns 200 |
| tmux sessions | spawned by `dws-sessions-init` | managed set present: `dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h orchestrator` |
| Cron | system `cron.service` | daemon active, 3 dev-workspace entries present |
| Launcher | `~/bin/dws-launcher.sh` | runnable on a fresh SSH login |
| Health / status | `dws-status.sh`, `dws-doctor.sh`, `dws-health.sh` | all three exit 0 |

## Preconditions

- You are on the Mac (or iPhone/Termius) and Tailscale is up.
- You are *not* holding uncommitted work in any tmux session you need to preserve — reboot kills tmux state.
- Merge freeze and coordination with the orchestrator Claude are agreed (no active workers mid-write to `~/projects/dev-workspace`).

## Phase 1 — Pre-reboot Prep

Capture a baseline so post-reboot deltas are detectable.

```bash
ssh moses@dev-workspace-vm '
  mkdir -p ~/reboot-drills/$(date -u +%Y%m%dT%H%M%SZ) &&
  cd ~/reboot-drills/$(date -u +%Y%m%dT%H%M%SZ) &&
  date -u > timestamp.txt &&
  uptime > uptime.before.txt &&
  tmux list-sessions > tmux.before.txt 2>&1 &&
  systemctl --user list-units --state=running --type=service > user-services.before.txt &&
  systemctl is-active tailscaled ssh ssh.socket cron > system-services.before.txt &&
  crontab -l > cron.before.txt &&
  tailscale status > tailscale.before.txt &&
  ~/projects/dev-workspace/scripts/dws-health.sh --json > health.before.json 2>/dev/null || true &&
  cp ~/projects/dev-workspace/.state/task-queue.json task-queue.before.json 2>/dev/null || true
'
```

Pass: baseline directory created with all files non-empty.
Fail: any capture errored out → investigate *before* rebooting (a failed capture often signals the stack is already sick).

Announce the reboot window to any other Claude/codex agents by appending to `/tmp/task-coordination.md` and dropping a notice in `/tmp/claude-wid39818-inbox`. Wait 60 s for active workers to checkpoint.

Verify Foundry key and recent backup:

```bash
ssh moses@dev-workspace-vm 'test -f ~/.config/wrkflo/foundry.env && echo FOUNDRY_OK'
ssh moses@dev-workspace-vm 'ls -lt ~/backups/ 2>/dev/null | head -3'
```

Pass: `FOUNDRY_OK` printed; most recent backup ≤ 24 h old.

## Phase 2 — Reboot Execution

```bash
ssh moses@dev-workspace-vm 'sudo reboot'
```

Expected: SSH connection drops within ~2 s. VM is unreachable for ~60–90 s (Azure Standard_DC-series cold boot typical).

Wait loop from the Mac:

```bash
until ssh -o ConnectTimeout=5 -o BatchMode=yes moses@dev-workspace-vm 'uptime -p' 2>/dev/null; do
  sleep 5
done
```

Pass: `uptime -p` returns within 180 s.
Fail: still unreachable after 5 min → consult Azure portal for VM status and fall through to **Rollback / Escalation**.

## Phase 3 — Post-reboot Verification

Run the canonical check first, then work through the supplementary checks below.

### 3.0 Automated smoke test

```bash
ssh moses@dev-workspace-vm '~/projects/dev-workspace/bin/dws-boot-verify.sh'
```

Pass: `STATUS: READY` in the final line, `0 failed`.
Fail: any `FAIL` line → note which component and continue to the targeted section below.

### 3.1 Tailscale

```bash
ssh moses@dev-workspace-vm 'systemctl is-active tailscaled && tailscale ip -4 && tailscale status | head -10'
```

Pass: `active`; IP `100.117.16.63`; peers list includes `mosess-macbook-air-3` and `openclaw-gateway-vm` as `Wrk-Flo@`.
Fail: daemon inactive → `sudo systemctl start tailscaled`; if peers absent → `sudo tailscale up --ssh --operator=moses --hostname=dev-workspace-vm --accept-routes`.

### 3.2 SSH (socket-activated)

```bash
ssh moses@dev-workspace-vm 'systemctl is-active ssh ssh.socket sshd; ss -tlnp | grep :22'
```

Pass: `ssh` = `active`, `ssh.socket` = `active`, `sshd` = `inactive` (that's normal — this distro names the unit `ssh`, not `sshd`, and socket activation hands off to `ssh.service` per connection). Port 22 is listening.
Fail: `ssh.socket` inactive → `sudo systemctl start ssh.socket`. Verify hardening config still in place: `grep -E 'PasswordAuth|PermitRootLogin|ClientAliveInterval' /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf` shows `no`, `no`, `30`.

### 3.3 User linger + systemd --user

```bash
ssh moses@dev-workspace-vm 'loginctl show-user moses -p Linger; systemctl --user list-units --state=running --type=service'
```

Pass: `Linger=yes`; `dws-phone-server.service`, `dws-task-monitor.service`, `wrkflo-orchestrator-api.service` all `running`; `dws-sessions-init.service` is `active (exited)` (oneshot, `RemainAfterExit=yes`).
Fail: `Linger=no` → user services did not auto-start on boot; run `sudo loginctl enable-linger moses` and reboot again.

### 3.4 dws-sessions-init.service

Runs once at boot before `dws-task-monitor.service` and spawns all expected tmux sessions.

```bash
ssh moses@dev-workspace-vm 'systemctl --user status dws-sessions-init.service --no-pager | head -15; journalctl --user -u dws-sessions-init.service -n 30 --no-pager'
```

Pass: `Active: active (exited)`, `Main PID: ... (code=exited, status=0/SUCCESS)`; log contains `sessions init complete: 9 sessions`.
Fail: non-zero exit → `journalctl --user -u dws-sessions-init.service -b` for root cause; rerun manually with `systemctl --user start dws-sessions-init.service`.

### 3.5 dws-task-monitor.service

```bash
ssh moses@dev-workspace-vm 'systemctl --user is-active dws-task-monitor.service; tail -n 20 /var/log/dws/monitor.log'
```

Pass: `active`; monitor log advancing with fresh `--- check cycle ...` lines (cycles every 30 s).
Fail: inactive or log frozen > 2 min → `systemctl --user restart dws-task-monitor.service`, then re-tail.

### 3.6 dws-phone-server.service

```bash
ssh moses@dev-workspace-vm 'systemctl --user is-active dws-phone-server.service; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8081/health || true'
```

Pass: `active`; `/health` returns `200`.
Fail: inactive → `journalctl --user -u dws-phone-server.service -n 50 --no-pager`; restart with `systemctl --user restart dws-phone-server.service`.

### 3.7 wrkflo-orchestrator-api.service

```bash
ssh moses@dev-workspace-vm 'systemctl --user is-active wrkflo-orchestrator-api.service; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8100/v1/workspace/health'
```

Pass: `active`; `/v1/workspace/health` returns `200`.
Fail: inactive or non-200 → `journalctl --user -u wrkflo-orchestrator-api.service -n 80 --no-pager`; common cause is missing `state.db` dir → `mkdir -p ~/.local/state/wrkflo-orchestrator` and restart.

### 3.8 tmux sessions

```bash
ssh moses@dev-workspace-vm 'tmux list-sessions'
```

Pass: the 9 managed sessions are present: `dws-a`, `dws-b`, `worker-c`, `worker-d`, `worker-e`, `worker-f`, `worker-g`, `worker-h`, `orchestrator`. Extra ad hoc sessions are acceptable but should be noted separately.
Fail: any managed session is missing → `systemctl --user restart dws-sessions-init.service`. If any session exists but codex is missing inside, inspect the session with `~/projects/dev-workspace/bin/dws-sessions.sh show <session>` before forcing a relaunch.

### 3.9 Cron

```bash
ssh moses@dev-workspace-vm 'systemctl is-active cron; crontab -l | grep -c "dev-workspace managed cron"'
```

Pass: `cron` = `active`; grep count ≥ 2 (opening and closing markers).
Full entry check:
```bash
ssh moses@dev-workspace-vm 'crontab -l | grep -E "dws-(health-check|log-rotate|session-cleanup)" | wc -l'
```
Pass: 3.
Fail: missing entries → reinstall with `~/projects/dev-workspace/bin/dws-cron-setup.sh`.

### 3.10 Launcher access

From a fresh shell (not a reattach):

```bash
ssh moses@dev-workspace-vm '~/projects/dev-workspace/scripts/dws-launcher.sh status'
```

Pass: the launcher status view prints its header and exits `0`.
Fail: launcher status errors out → `bash -x ~/projects/dev-workspace/scripts/dws-launcher.sh status` to surface the failing line; confirm `~/projects/dev-workspace/scripts/dws-launcher.sh` is present and executable.

### 3.11 Health / status commands

```bash
ssh moses@dev-workspace-vm '
  ~/projects/dev-workspace/bin/dws-status.sh &&
  ~/projects/dev-workspace/bin/dws-doctor.sh &&
  ~/projects/dev-workspace/scripts/dws-health.sh --json > /tmp/dws-health.current.json &&
  jq -e ".tailnet.connected == true and .tools.foundry_key_loaded == true and .services.dws_task_monitor.healthy == true and .services.dws_sessions_init.healthy == true" /tmp/dws-health.current.json >/dev/null
'
```

Pass: all commands exit `0`; `dws-status.sh` shows the managed session set; `dws-doctor.sh` has no `FAIL` lines; the `dws-health.sh --json` payload reports `tailnet.connected=true`, `tools.foundry_key_loaded=true`, and both managed user services healthy.
Fail: any script exits non-zero → section-specific recovery above, then rerun the failing script.

## Phase 4 — Sign-off

The drill is green when **all** of the following hold:

- `~/projects/dev-workspace/bin/dws-boot-verify.sh` reports `STATUS: READY`, `0 failed`.
- Sections 3.1 – 3.11 each show their pass criterion.
- `tmux list-sessions` shows the managed 9-session pool.
- `~/projects/dev-workspace/scripts/dws-health.sh --json` returns healthy service state after the reboot.
- Monitor log advanced at least 2 cycles (1 min) since boot.

Append a sign-off line to the baseline directory created in Phase 1:

```bash
ssh moses@dev-workspace-vm 'echo "SIGNOFF $(date -u +%Y-%m-%dT%H:%M:%SZ) green" >> ~/reboot-drills/*/timestamp.txt'
```

## Rollback / Escalation

| Symptom | First action | Escalation |
|---|---|---|
| VM unreachable > 5 min after reboot | Azure portal → VM status; try Serial Console | Open an Azure support ticket; if prolonged, cut traffic back to `openclaw-gateway-vm` for any user-facing work |
| `ssh.socket` inactive on boot | `sudo systemctl start ssh.socket`; check journal | If recurring, re-enable: `sudo systemctl enable --now ssh.socket` and add to `dws-boot-verify.sh` hard fail list |
| User services not starting (linger off) | `sudo loginctl enable-linger moses` then reboot | If linger is already on but services still not starting, inspect `systemctl --user --failed` and `journalctl --user -b` |
| tmux sessions missing after `dws-sessions-init` | `systemctl --user restart dws-sessions-init.service` | If repeated failures, check `~/.config/wrkflo/foundry.env` exists; codex needs the API key loaded |
| `wrkflo-orchestrator-api` failing | `journalctl --user -u wrkflo-orchestrator-api.service -b`; ensure `~/.local/state/wrkflo-orchestrator/` exists | Fall back to direct file edits via ssh + git; the API is a convenience layer |
| Tailscale down, SSH via public IP only | `sudo systemctl restart tailscaled`; if key expired, re-auth via the URL printed by `sudo tailscale up --ssh --operator=moses` | If tailnet unreachable org-wide, verify account billing status |
| `/var/log/dws/` missing or not writable | `sudo mkdir -p /var/log/dws && sudo chown moses:moses /var/log/dws` | Fold this into `vm-bootstrap.sh` so fresh provisions have it |

**Never skip a failed check.** A silent partial-boot is the class of failure this drill exists to catch. If any section fails and cannot be recovered in-place within 10 min, take the drill result as a **blocking** incident: stop dispatching new work to the VM, announce via `/tmp/task-coordination.md`, and page the operator.

## References

- `~/projects/dev-workspace/bin/dws-boot-verify.sh` — automated smoke test (source of truth for mechanical checks)
- `~/projects/dev-workspace/docs/runbook.md` — standard operator procedures
- `~/projects/dev-workspace/docs/architecture.md` — component diagram
- `~/projects/dev-workspace/docs/risk-register-dev-workspace.md` — known failure modes
- `/tmp/task-coordination.md` — live claim/release ledger across agents
