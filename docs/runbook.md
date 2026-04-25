# Dev Workspace Runbook

Operational procedures for the `dev-workspace-vm` multi-agent environment.

## Quick Reference

| Item | Location |
| --- | --- |
| Repo | `~/projects/dev-workspace` |
| Managed queue | `~/projects/dev-workspace/.state/task-queue.json` |
| Repo wrappers | `~/projects/dev-workspace/bin/` |
| Repo scripts | `~/projects/dev-workspace/scripts/` |
| VM-local service entrypoints | `~/bin/` |
| Repo-managed user services | `~/.config/systemd/user/dws-sessions-init.service`, `~/.config/systemd/user/dws-safe-mode.service` |
| Installed sibling-repo user service | `~/.config/systemd/user/wrkflo-orchestrator-api.service` |
| Orchestrator unit source | `~/projects/wrkflo-orchestrator/ops/systemd/wrkflo-orchestrator-api.service` |
| Optional host-local services | `dws-task-monitor.service` when installed |
| Service installer | `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh` |
| Orchestrator API base URL | `http://127.0.0.1:8100` |
| Optional host-local monitor log | `/var/log/dws/monitor.log` when a host-local monitor is installed |
| Boot verifier | `~/projects/dev-workspace/bin/dws-boot-verify.sh` |
| Launcher status | `~/projects/dev-workspace/scripts/dws-launcher.sh status` |
| `dws-summary` | `~/projects/dev-workspace/bin/dws-summary.sh` |
| `dws-alerting` | `~/projects/dev-workspace/bin/dws-alerting.sh` |
| `dws-queue-inspector` | `~/projects/dev-workspace/bin/dws-queue-inspector.sh` |
| `dws-termius-verify` | `~/projects/dev-workspace/bin/dws-termius-verify.sh` |
| `dws-reboot-drill` | `~/projects/dev-workspace/bin/dws-reboot-drill.sh` |
| `dws-service-map` | `~/projects/dev-workspace/bin/dws-service-map.sh` |
| `dws-maintenance-mode.sh` | `~/projects/dev-workspace/bin/dws-maintenance-mode.sh` |
| `dws-pause-dispatch.sh` | `~/projects/dev-workspace/bin/dws-pause-dispatch.sh` |
| `dws-incident-export.sh` | `~/projects/dev-workspace/bin/dws-incident-export.sh` |
| `dws-worker-exec.sh` | `~/projects/dev-workspace/scripts/dws-worker-exec.sh` |
| `dws-termius-mac-fix.sh` | `~/projects/dev-workspace/bin/dws-termius-mac-fix.sh` |
| `dws-safe-mode.sh` | `~/projects/dev-workspace/bin/dws-safe-mode.sh` |
| SSH hardening (live) | `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf` |
| SSH baseline (repo) | `~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf` |
| Foundry env | `~/.config/wrkflo/foundry.env` |

## Tailscale Network

| Device | IP |
| --- | --- |
| dev-workspace-vm | `100.117.16.63` |
| Mac | `100.78.207.22` |
| iPhone | `100.88.249.22` |
| openclaw-gateway | `100.126.194.98` |

## Start / Resume

### After reboot (automatic)

The service-managed boot path on the live VM is:

1. `dws-sessions-init.service` is enabled at boot and finishes
   `active (exited)` with `Result=success`.
2. `wrkflo-orchestrator-api.service` is enabled at boot and remains
   `active (running)` on `127.0.0.1:8100`.
3. `dws-safe-mode.service` is installed, matches the repo unit, and stays
   disabled unless the operator intentionally enables maintenance mode.
4. `dws-task-monitor.service` remains optional and may be absent on healthy
   hosts.

Verify the steady-state stack with:

```bash
systemctl --user is-enabled \
  dws-sessions-init.service \
  wrkflo-orchestrator-api.service \
  dws-safe-mode.service
systemctl --user show -p ActiveState -p SubState -p Result \
  dws-sessions-init.service \
  wrkflo-orchestrator-api.service \
  dws-safe-mode.service
systemctl --user status \
  dws-sessions-init.service \
  wrkflo-orchestrator-api.service \
  dws-safe-mode.service \
  --no-pager
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check
~/projects/dev-workspace/bin/dws-service-map.sh
~/projects/dev-workspace/bin/dws-boot-verify.sh
cmp -s ~/projects/dev-workspace/config/systemd-user/dws-safe-mode.service \
  ~/.config/systemd/user/dws-safe-mode.service \
  && echo "dws-safe-mode.service matches repo"
cmp -s ~/projects/wrkflo-orchestrator/ops/systemd/wrkflo-orchestrator-api.service \
  ~/.config/systemd/user/wrkflo-orchestrator-api.service \
  && echo "wrkflo-orchestrator-api.service matches sibling repo"
base=http://127.0.0.1:8100
for path in \
  /healthz \
  /readyz \
  /v1/workspace/health \
  /v1/workers \
  /v1/projects \
  /v1/workspace/projects \
  /v1/tasks/history
do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$base$path")
  printf '%s  %s\n' "$code" "$path"
done
```

Expected steady state:
`dws-sessions-init.service` = `enabled`, `active`, `exited`, `success`;
`wrkflo-orchestrator-api.service` = `enabled`, `active`, `running`,
`success`; `dws-safe-mode.service` = `disabled`, `inactive`; every listed HTTP
endpoint returns `200`.

Optional host-local monitor checks when installed:

```bash
systemctl --user status dws-task-monitor.service --no-pager
tail -n 20 /var/log/dws/monitor.log
```

### Manual repair

If the dev-workspace user units are missing or stale:

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
install -D -m 0644 \
  ~/projects/wrkflo-orchestrator/ops/systemd/wrkflo-orchestrator-api.service \
  ~/.config/systemd/user/wrkflo-orchestrator-api.service
systemctl --user daemon-reload
systemctl --user enable --now wrkflo-orchestrator-api.service
```

If the units are installed but the runtime needs to be rebuilt:

```bash
systemctl --user restart wrkflo-orchestrator-api.service
systemctl --user restart dws-sessions-init.service
```

`dws-safe-mode.service` stays disabled by default. If you intentionally enabled
safe mode earlier, clear it with `~/projects/dev-workspace/bin/dws-safe-mode.sh off`.
Normal steady state is `installed + disabled`; do not enable the unit during
routine boot.

The dev-workspace installer manages only the `dws-*` user units. The
orchestrator control-plane unit is installed from the sibling
`wrkflo-orchestrator` repo, and `dws-task-monitor.service` remains optional.
Restart the monitor only if the host actually installs it.

## Stop

### Pause repo-managed session/bootstrap behavior

```bash
~/projects/dev-workspace/bin/dws-safe-mode.sh on
```

### Full stop (pause repo-managed boot flow and kill currently active sessions if needed)

```bash
~/projects/dev-workspace/bin/dws-safe-mode.sh on
tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
  [ -n "$s" ] || continue
  tmux kill-session -t "$s" 2>/dev/null || true
done
```

## Optional Host-Local Monitor

Use this section only on hosts that still install `dws-task-monitor.service`
and `~/bin/task-monitor.sh`.

### Check status

```bash
systemctl --user status dws-task-monitor.service --no-pager
journalctl --user -u dws-task-monitor.service -n 40 --no-pager
tail -n 20 /var/log/dws/monitor.log
```

### Restart monitor

```bash
systemctl --user restart dws-task-monitor.service
tail -n 40 /var/log/dws/monitor.log
```

### View the live log

```bash
tail -f /var/log/dws/monitor.log
```

### Pause new task dispatch

```bash
~/projects/dev-workspace/bin/dws-pause-dispatch.sh on
~/projects/dev-workspace/bin/dws-pause-dispatch.sh status
~/projects/dev-workspace/bin/dws-pause-dispatch.sh off
```

This creates `/tmp/dws-dispatch-paused`. It only affects hosts that still run
the host-local `task-monitor.sh`.

### Export an incident bundle

```bash
~/projects/dev-workspace/bin/dws-incident-export.sh
```

The archive lands at `/tmp/dws-incident-TIMESTAMP.tar.gz` and includes the last
200 lines of `/var/log/dws/monitor.log` when present, the current queue JSON,
`tmux list-sessions`, `systemctl --user status`, `tailscale status`,
`ufw status`, `df -h`,
`free -h`, and `uptime`.

## Ops Hardening

Recent alerting and monitoring work adds dedicated operator surfaces so queue
stalls, service drift, and recovery regressions show up before they become a
manual incident.

| Tool | Purpose |
| --- | --- |
| `~/projects/dev-workspace/bin/dws-alerting.sh` | Append alerts to `/var/log/dws/alerts.log` for monitor restart loops, repeated rate limits, missing Tailscale peers, disk pressure, and recent cron failures. |
| `~/projects/dev-workspace/bin/dws-queue-inspector.sh` | Summarize queue depth, per-worker assignment counts, and completion rates; use `--json` when piping into other tooling. |
| `~/projects/dev-workspace/bin/dws-service-map.sh` | Show the current user-systemd boot order and runtime state for repo-managed units, plus optional host-local units when they are installed. |
| `~/projects/dev-workspace/bin/dws-pause-dispatch.sh` | Create or clear `/tmp/dws-dispatch-paused` for hosts that still run the host-local `task-monitor.sh`. |
| `~/projects/dev-workspace/bin/dws-incident-export.sh` | Capture an incident bundle under `/tmp/dws-incident-TIMESTAMP.tar.gz` with queue, tmux, service, network, disk, memory, uptime, and optional monitor snapshots. |
| `~/projects/dev-workspace/scripts/dws-worker-exec.sh` | Execute a single queued task JSON, write `.state/results/<task-id>.log` and `.json`, and mark the queue item `completed` or `failed`. |
| `~/projects/dev-workspace/bin/dws-termius-mac-fix.sh` | Repair macOS SSH pubkey settings and file permissions when Termius key auth breaks on the Mac side. |
| `~/projects/dev-workspace/bin/dws-safe-mode.sh` | Stop worker dispatch and session management while leaving SSH, Tailscale, health checks, and log rotation available. |
| `~/projects/dev-workspace/bin/dws-worker-utilization.sh` | Parse `/var/log/dws/monitor.log` into per-worker completions, rate-limit hits, idle percentage, and average task duration when that host-local monitor log exists. |
| `~/projects/dev-workspace/bin/dws-termius-verify.sh` | Validate the phone access path before relying on Termius during recovery drills or off-Mac operations. |

Use `dws-maintenance-mode.sh` before planned interventions to stop new task
dispatch cleanly, and pair `dws-reboot-drill.sh` with
`~/projects/dev-workspace/bin/dws-boot-verify.sh` when rehearsing reboot
recovery. The goal is to keep alerting, queue visibility, and service topology
observable from one repo-managed surface instead of ad hoc shell commands.

## Task Queue

### Check queue counts

```bash
jq -r '
  .tasks as $tasks
  | "pending=\($tasks | map(select(.status == \"pending\")) | length)"
  , "in_progress=\($tasks | map(select(.status == \"in_progress\")) | length)"
  , "completed=\($tasks | map(select(.status == \"completed\")) | length)"
' ~/projects/dev-workspace/.state/task-queue.json
```

### Inspect active assignments

```bash
jq -r '.tasks[]? | select(.status == "in_progress") | [.id, .assigned, .repo] | @tsv' \
  ~/projects/dev-workspace/.state/task-queue.json
```

### Execute one queued task by id

```bash
~/projects/dev-workspace/scripts/dws-worker-exec.sh <task-id>
```

This reads `.state/tasks/<task-id>.json`, runs the command in the task repo,
writes `.state/results/<task-id>.log` and `.json`, and updates
`.state/task-queue.json` to `completed` or `failed`.

## tmux Sessions

### Managed-session view

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
```

### Raw `tmux`

```bash
tmux list-sessions
tmux attach-session -t <session>
tmux capture-pane -t <session> -p | tail -10
```

Replace `<session>` with a live name from `tmux list-sessions` or
`~/projects/dev-workspace/bin/dws-sessions.sh list`; the repo no longer
guarantees fixed `dws-a` or `worker-*` session names.

Detach with `Ctrl-a d`.

## SSH

### Inspect the live config

```bash
sudo sh -c 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -e "$f" ] || continue; echo "--- $f ---"; sed -n "1,160p" "$f"; done'
grep -E 'PasswordAuthentication|PermitRootLogin|ClientAliveInterval' /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -t
```

### Reload SSH safely

```bash
sudo systemctl reload ssh || sudo systemctl restart ssh
```

### Lockout recovery

1. Keep one working shell open.
2. If a hardening drop-in caused the lockout, move it aside and validate:

```bash
sudo mv /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf.disabled 2>/dev/null || true
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

3. Restore the repo baseline after a fresh login works again:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo install -m 0644 \
  ~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf \
  /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

## Backup / Restore

### Backup

```bash
~/projects/dev-workspace/bin/dws-backup.sh backup
```

### Verify restoreability and prune old archives

```bash
~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest --prune
```

### Restore

```bash
~/projects/dev-workspace/bin/dws-backup.sh restore latest
```

## Update Repo-Managed Assets

```bash
cd ~/projects/dev-workspace
git pull --ff-only
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check || \
  ~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
```

`git pull` updates the checked-in repo only. If you rely on copied helpers under
`~/bin`, redeploy them with your normal host update path before you trust the
live service entrypoints again.

## Reboot Recovery

Full drill: `docs/reboot-recovery-test.md`

Quick path:

```bash
sudo reboot
# Wait 60-90s
ssh dev-workspace-vm '~/projects/dev-workspace/bin/dws-boot-verify.sh'
```

## Phone / Termius Access

1. Install Termius on the iPhone.
2. Add host: hostname `dev-workspace-vm` (preferred) or the current Tailscale
   IP shown by `~/projects/dev-workspace/bin/dws-termius-setup.sh`, port `22`,
   user `moses`.
3. Import the SSH key shown by `~/projects/dev-workspace/bin/dws-termius-setup.sh`.
4. Connect with Tailscale enabled on the phone.
5. Reconnect to work with `~/projects/dev-workspace/bin/dws-sessions.sh reconnect`.

If Termius key auth breaks because macOS `sshd` or `~/.ssh` permissions drifted,
run on the Mac:

```bash
~/projects/dev-workspace/bin/dws-termius-mac-fix.sh
```

See `docs/termius-setup.md` for the full setup flow.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Optional host-local monitor down | `systemctl --user restart dws-task-monitor.service` |
| Orchestrator API unhealthy | `systemctl --user restart wrkflo-orchestrator-api.service` and rerun the `127.0.0.1:8100` curl sweep from Start / Resume |
| Managed sessions missing | `systemctl --user restart dws-sessions-init.service` |
| Safe mode still enabled | `~/projects/dev-workspace/bin/dws-safe-mode.sh off` |
| Queue looks wrong | inspect `~/projects/dev-workspace/.state/task-queue.json` and compare against `dws-sessions.sh list` |
| Need an incident handoff bundle | `~/projects/dev-workspace/bin/dws-incident-export.sh` |
| SSH dropped | reconnect and use `dws-sessions.sh reconnect` |
| Cron drift | `~/projects/dev-workspace/bin/dws-cron-setup.sh` |
| Firewall rollback needed | use the steps in `docs/troubleshooting.md` |

## Cron Jobs

Inspect the managed block with:

```bash
crontab -l | sed -n '/# >>> dev-workspace managed cron >>>/,/# <<< dev-workspace managed cron <<</p'
```

Current schedules from `dws-cron-setup.sh`:

- `*/15 * * * *` — `dws-health-check.sh`
- `30 2 * * 0` — `dws-rotate-logs.sh`
- `0 4 * * *` — `dws-cleanup.sh --session-hours 24 --log-days 7 --temp-days 365000`

The cron installer does not take an `install` subcommand. Re-run the installer
with:

```bash
~/projects/dev-workspace/bin/dws-cron-setup.sh
```

The tracked installer now defaults managed cron logs to `/var/log/dws`. If this
VM is still writing the older `/tmp/dws-*.cron.log` files, rerun the installer
to converge the live crontab:

```bash
DWS_CRON_LOG_DIR=/var/log/dws ~/projects/dev-workspace/bin/dws-cron-setup.sh
```

## Self-Healing Stack

```text
Layer 4: Tailscale + SSH reconnect         -> operator reconnects to an existing session
Layer 3: optional host-local task monitor  -> may manage queue/worker recreation on drifted hosts
Layer 2: wrkflo-orchestrator-api.service   -> enabled user service serving the local control plane on 127.0.0.1:8100
Layer 1: dws-sessions-init.service         -> repo-managed boot-time prep for the on-demand session model
```

## Mac Reconnect Agent

The `com.wrkflo.terminal-reconnect` LaunchAgent on the Mac auto-reopens SSH terminal
windows when they close. It is **intentionally optional** — load it only when you want
unattended terminal persistence:

```bash
# Enable (auto-relaunch terminals on disconnect)
launchctl load ~/Library/LaunchAgents/com.wrkflo.terminal-reconnect.plist

# Disable (manual terminal management)
launchctl unload ~/Library/LaunchAgents/com.wrkflo.terminal-reconnect.plist
```

Default: **disabled**. The VM-side steady-state user services are
`dws-sessions-init.service` and `wrkflo-orchestrator-api.service`, and some
hosts may also run optional host-local services such as `dws-task-monitor`.
The Mac agent is only needed when you want the Mac to maintain persistent SSH
windows for visual monitoring.

## Rate-Aware Dispatch

Hosts that still run the host-local task monitor include global rate-limit
awareness:

- **Per-worker**: exponential backoff (30s → 60s → 120s) on rate limit detection
- **Global throttle**: if 3+ workers hit rate limits within a 5-minute window, all
  dispatch pauses for 120s to let the API recover
- **Staggered dispatch**: 3s delay between consecutive worker dispatches in the same cycle

To check throttle state: `tail -20 /var/log/dws/monitor.log | grep -i rate`

## Safe Mode

Safe mode stops `dws-sessions-init.service` and
`wrkflo-orchestrator-api.service`. The safe-mode wrapper also stops any
installed `dws-task-monitor.service` while keeping SSH, Tailscale, health
checks, and log rotation running. Use for upgrades, incident response, or
debugging.

```bash
# Enter safe mode
~/projects/dev-workspace/bin/dws-safe-mode.sh on

# Check status
~/projects/dev-workspace/bin/dws-safe-mode.sh status

# Exit safe mode
~/projects/dev-workspace/bin/dws-safe-mode.sh off
```
