# Dev Workspace Runbook

Operational procedures for the `dev-workspace-vm` multi-agent environment.

## Quick Reference

| Item | Location / command |
| --- | --- |
| Repo | `~/projects/dev-workspace` |
| Repo wrappers | `~/projects/dev-workspace/bin/` |
| Repo scripts | `~/projects/dev-workspace/scripts/` |
| VM-local service entrypoints | `~/bin/` |
| Managed queue | `~/projects/dev-workspace/.state/task-queue.json` |
| Authoritative monitor log | `/var/log/dws/monitor.log` |
| User services | `dws-sessions-init.service`, `dws-task-monitor.service` |
| Service installer | `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh` |
| Health dashboard | `~/projects/dev-workspace/scripts/dws-health.sh` |
| Status view | `~/projects/dev-workspace/bin/dws-status.sh` |
| Session recovery | `~/projects/dev-workspace/bin/dws-sessions.sh` |
| Backup tool | `~/projects/dev-workspace/bin/dws-backup.sh` |
| Cron installer | `~/projects/dev-workspace/bin/dws-cron-setup.sh` |
| Termius helper | `~/projects/dev-workspace/bin/dws-termius-setup.sh` |
| Tailscale diagnostics | `~/projects/dev-workspace/bin/dws-tailscale-diag.sh` |
| SSH hardening (live) | `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf` |
| SSH baseline (repo) | `~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf` |
| Foundry env | `~/.config/wrkflo/foundry.env` |
| Boot verifier (safe invocation) | `DWS_BOOT_VERIFY_TASK_MONITOR_UNIT=dws-task-monitor.service ~/projects/dev-workspace/bin/dws-boot-verify.sh` |

## Runtime Truth

- Treat `~/projects/dev-workspace/.state/task-queue.json` as the live queue.
- Treat `/var/log/dws/monitor.log` as the live monitor cycle log.
- When repo tooling disagrees with live state, trust `systemctl --user`, the
  live queue, and the live monitor log first.
- `dws-task-monitor.service` is the normal monitor control surface.
- A legacy `monitor` `tmux` session may still appear depending on which
  `~/bin/dws-sessions-init.sh` is deployed. Do not use that as the primary
  control surface unless you are debugging legacy behavior.
- Some repo readers still default to `/tmp/task-queue.json` or
  `/tmp/monitor-log.txt`; those are legacy paths, not the authoritative runtime
  surfaces.

## Tailscale Network

| Device | IP |
| --- | --- |
| dev-workspace-vm | `100.117.16.63` |
| Mac | `100.78.207.22` |
| iPhone | `100.88.249.22` |
| openclaw-gateway | `100.126.194.98` |

## Start / Resume

### Fast health snapshot

```bash
~/projects/dev-workspace/scripts/dws-health.sh
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-sessions.sh list
```

### Automatic after reboot

The service-managed boot path is:

1. `dws-sessions-init.service` recreates the managed `tmux` pool.
2. `dws-task-monitor.service` starts the monitor loop after session init.

Verify the stack with:

```bash
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
journalctl --user -u dws-task-monitor.service -n 40 --no-pager
tail -n 40 /var/log/dws/monitor.log
~/projects/dev-workspace/scripts/dws-health.sh --json | jq '.services, .security, .tailnet'
DWS_BOOT_VERIFY_TASK_MONITOR_UNIT=dws-task-monitor.service \
  ~/projects/dev-workspace/bin/dws-boot-verify.sh
```

### Manual rebuild

If the user units are missing or stale:

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user daemon-reload
systemctl --user reset-failed
```

If the runtime needs to be rebuilt:

```bash
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
tmux list-sessions
```

Use the user services as the normal control surface. Do not rely on a dedicated
`monitor` `tmux` session for normal operations.

### After repo updates

```bash
cd ~/projects/dev-workspace
git pull --ff-only
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check || \
  ~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
```

`git pull` updates the checked-in repo only. If you rely on copied helpers under
`~/bin`, redeploy those through your normal host update path before trusting
service-managed entrypoints again.

## Stop

### Pause the monitor but keep worker sessions

```bash
systemctl --user stop dws-task-monitor.service
```

### Full stop

```bash
systemctl --user stop dws-task-monitor.service
for s in dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h orchestrator monitor; do
  tmux kill-session -t "$s" 2>/dev/null || true
done
```

### Disconnect without killing work

Detach from `tmux` with `Ctrl-a d`, then close the SSH client.

## Monitor Management

### Check monitor and worker health

```bash
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
systemctl --user status dws-task-monitor.service --no-pager
journalctl --user -u dws-task-monitor.service -n 40 --no-pager
tail -n 40 /var/log/dws/monitor.log
sed -n '1,160p' ~/projects/dev-workspace/.state/task-queue.json
tmux list-sessions
```

### Restart the monitor

```bash
systemctl --user restart dws-task-monitor.service
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```

### Rebuild the managed session pool

```bash
systemctl --user restart dws-sessions-init.service
tmux list-sessions
```

### View the live log

```bash
tail -f /var/log/dws/monitor.log
```

### Optional local health endpoints

```bash
curl -sSf http://127.0.0.1:8100/v1/workspace/health
curl -sSf http://127.0.0.1:8081/health
```

If the service state, the live log, and `tmux` disagree, trust the service
state and `/var/log/dws/monitor.log` first.

## Task Queue

### Count task states

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

### Snapshot before a manual queue edit

```bash
cp ~/projects/dev-workspace/.state/task-queue.json \
  ~/projects/dev-workspace/.state/task-queue.json.$(date -u +%Y%m%dT%H%M%SZ).bak
jq . ~/projects/dev-workspace/.state/task-queue.json >/dev/null
```

### Validate after a queue repair

```bash
jq . ~/projects/dev-workspace/.state/task-queue.json >/dev/null
systemctl --user restart dws-task-monitor.service
~/projects/dev-workspace/bin/dws-sessions.sh list
tail -n 40 /var/log/dws/monitor.log
```

If the queue is corrupted or obviously older than the newest good snapshot,
restore from backup and restart the monitor after the restore completes.

## tmux Sessions

### Managed-session view

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
~/projects/dev-workspace/bin/dws-sessions.sh recover <session>
~/projects/dev-workspace/bin/dws-sessions.sh relaunch <session>
```

### Raw `tmux`

```bash
tmux list-sessions
tmux attach-session -t dws-a
tmux capture-pane -t worker-c -p | tail -10
```

Detach with `Ctrl-a d`.

## Backup / Restore

`dws-backup.sh` captures:

- `~/.config/wrkflo/`
- `~/bin/`
- `~/.ssh/`
- user crontab and `tmux` layouts
- git metadata for repos under `~/projects/`

### Create a backup

```bash
~/projects/dev-workspace/bin/dws-backup.sh backup
```

### Verify the latest backup and prune old snapshots

```bash
~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest --prune
```

### Restore the latest backup in place

```bash
~/projects/dev-workspace/bin/dws-backup.sh restore latest
```

### Restore to a scratch target first

```bash
~/projects/dev-workspace/bin/dws-backup.sh restore latest --target /tmp/dws-restore-check
```

### Post-restore bring-up

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user daemon-reload
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
~/projects/dev-workspace/scripts/dws-health.sh --json | jq '.services, .security, .tailnet'
```

There is no separate backup-prune command. Use `verify-restore --prune` or
`~/projects/dev-workspace/bin/dws-backup.sh cron`.

## Reboot Recovery

Full drill: `docs/reboot-recovery-test.md`

### Quick reboot drill

```bash
ssh moses@dev-workspace-vm 'sudo reboot'
until ssh -o ConnectTimeout=5 -o BatchMode=yes moses@dev-workspace-vm 'uptime -p' 2>/dev/null; do
  sleep 5
done
ssh moses@dev-workspace-vm '
  systemctl --user status dws-sessions-init.service --no-pager &&
  systemctl --user status dws-task-monitor.service --no-pager &&
  tail -n 20 /var/log/dws/monitor.log
'
ssh moses@dev-workspace-vm '
  DWS_BOOT_VERIFY_TASK_MONITOR_UNIT=dws-task-monitor.service \
  ~/projects/dev-workspace/bin/dws-boot-verify.sh
'
```

### If the quick drill fails

```bash
ssh moses@dev-workspace-vm '
  ~/projects/dev-workspace/scripts/dws-health.sh &&
  ~/projects/dev-workspace/bin/dws-status.sh &&
  ~/projects/dev-workspace/bin/dws-sessions.sh list
'
```

Then use the targeted monitor, queue, SSH, or Tailscale recovery sections below.

## SSH Recovery

### Inspect the live SSH config and service state

```bash
sudo sh -c 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -e "$f" ] || continue; echo "--- $f ---"; sed -n "1,200p" "$f"; done'
grep -E 'PasswordAuthentication|PermitRootLogin|ClientAliveInterval' /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -t
systemctl is-active ssh ssh.socket sshd sshd.socket
```

### Reload SSH safely

```bash
sudo systemctl reload ssh || sudo systemctl restart ssh
```

### Lockout recovery

1. Keep one working shell, Tailscale session, or serial-console path open.
2. If a hardening drop-in caused the lockout, disable it and reload SSH:

```bash
sudo mv /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf.disabled 2>/dev/null || true
sudo mv /etc/ssh/sshd_config.d/zz-dws-hardening.conf /etc/ssh/sshd_config.d/zz-dws-hardening.conf.disabled 2>/dev/null || true
sudo mv /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf.disabled 2>/dev/null || true
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

3. Restore the repo baseline only after a fresh login works:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo install -m 0644 \
  ~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf \
  /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

4. Verify keys and recent SSH outcomes before closing the last working shell:

```bash
ls -l ~/.ssh/authorized_keys ~/.ssh/termius_20260415 ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null
journalctl -u ssh --since '24 hours ago' --no-pager | rg 'Accepted publickey|Failed publickey|Failed password'
```

If the ordinary SSH path dropped but the VM is still up, reconnect over
Tailscale or Termius first, then use `~/projects/dev-workspace/bin/dws-sessions.sh reconnect`.

## Phone / Termius Access

### Print the current host values and SSH key path

```bash
~/projects/dev-workspace/bin/dws-termius-setup.sh
```

Use the reported host, port, username, and key path for iPhone or desktop
Termius. Leave the startup command blank so the dev-workspace launcher runs.

### Recommended Termius settings

- Authentication: SSH key
- Keepalive interval: `30` seconds
- Terminal type: `xterm-256color`
- Character encoding: `UTF-8`
- Local echo: off
- Mosh: off
- SSH agent forwarding: off

### Working from the phone

1. Make sure Tailscale is connected on the phone.
2. Import the same private key shown by `dws-termius-setup.sh`.
3. Connect to the VM.
4. Reattach to work with:

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh reconnect
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
```

5. Detach cleanly with `Ctrl-a d` before closing the phone session.

### If phone login fails

```bash
ls -l ~/.ssh/termius_20260415 ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null
DWS_TERMIUS_KEY="$(~/projects/dev-workspace/bin/dws-termius-setup.sh | sed -n 's/^  SSH key path: \([^ ]*\) (.*/\1/p')"
ssh -i "$DWS_TERMIUS_KEY" -o BatchMode=yes -o ConnectTimeout=5 moses@100.117.16.63 'printf phone-key-ok\n'
journalctl -u ssh --since '24 hours ago' --no-pager | rg '100\.88\.249\.22|iphone-15-pro-max|Accepted publickey|Failed publickey'
```

Use landscape mode when you are actively working inside `tmux`, Codex, or Claude.

## Troubleshooting

### Fast triage

```bash
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
~/projects/dev-workspace/bin/dws-sessions.sh list
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```

### Common fixes

| Symptom | First action |
| --- | --- |
| Monitor down | `systemctl --user restart dws-task-monitor.service` |
| Managed sessions missing | `systemctl --user restart dws-sessions-init.service` |
| Queue stale or inconsistent | back up first, validate `.state/task-queue.json`, then `systemctl --user restart dws-task-monitor.service` |
| SSH dropped | reconnect over Tailscale or Termius, then `~/projects/dev-workspace/bin/dws-sessions.sh reconnect` |
| Tailscale disconnected | `~/projects/dev-workspace/bin/dws-tailscale-diag.sh`, then `sudo systemctl restart tailscaled` |
| Phone login broken | rerun `~/projects/dev-workspace/bin/dws-termius-setup.sh`, reimport the key, test from desktop first |
| Firewall rollback needed | disable `ufw` or remove the repo chain, then reapply policy only after SSH and Tailscale are stable |
| Cron drift | rerun `~/projects/dev-workspace/bin/dws-cron-setup.sh` |

### Cron block inspection

```bash
crontab -l | sed -n '/# >>> dev-workspace managed cron >>>/,/# <<< dev-workspace managed cron <<</p'
```

Current schedules from `dws-cron-setup.sh`:

- `*/15 * * * *` — `dws-health-check.sh`
- `30 2 * * 0` — `dws-rotate-logs.sh`
- `0 4 * * *` — `dws-cleanup.sh --session-hours 24 --log-days 7 --temp-days 365000`

Reinstall the managed block with:

```bash
~/projects/dev-workspace/bin/dws-cron-setup.sh
```

If you want cron logs centralized under `/var/log/dws`, reinstall with:

```bash
DWS_CRON_LOG_DIR=/var/log/dws ~/projects/dev-workspace/bin/dws-cron-setup.sh
```

For deeper procedures, use:

- `docs/troubleshooting.md`
- `docs/reboot-recovery-test.md`
- `docs/logging.md`
- `docs/termius-setup.md`

## Self-Healing Stack

```text
Layer 3: Tailscale + SSH reconnect         -> operator reconnects to an existing session
Layer 2: dws-task-monitor.service          -> relaunches crashed or compacted workers
Layer 1: dws-sessions-init.service         -> recreates the managed tmux pool after boot
```
