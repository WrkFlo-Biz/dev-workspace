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
| User services | `~/.config/systemd/user/dws-sessions-init.service`, `~/.config/systemd/user/dws-task-monitor.service` |
| Service installer | `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh` |
| Monitor log | `/var/log/dws/monitor.log` |
| Boot verifier | `~/projects/dev-workspace/bin/dws-boot-verify.sh` |
| Launcher status | `~/projects/dev-workspace/scripts/dws-launcher.sh status` |
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

The service-managed boot path is:

1. `dws-sessions-init.service` recreates the managed `tmux` pool.
2. `dws-task-monitor.service` starts the monitor loop after session init.

Verify the stack with:

```bash
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
tail -n 20 /var/log/dws/monitor.log
~/projects/dev-workspace/bin/dws-boot-verify.sh
```

### Manual repair

If the user units are missing or stale:

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user daemon-reload
```

If the units are installed but the runtime needs to be rebuilt:

```bash
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
```

Use the user services as the normal control surface. Do not launch
`~/bin/task-monitor.sh` in a dedicated `tmux` session unless you are debugging
the service path itself.

## Stop

### Graceful stop (keep worker sessions)

```bash
systemctl --user stop dws-task-monitor.service
```

### Full stop (stop monitor and kill the managed pool)

```bash
systemctl --user stop dws-task-monitor.service
for s in dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h orchestrator; do
  tmux kill-session -t "$s" 2>/dev/null || true
done
```

## Monitor Management

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
tmux attach-session -t dws-a
tmux capture-pane -t worker-c -p | tail -10
```

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
2. Add host: IP `100.117.16.63`, port `22`, user `moses`.
3. Import the SSH key shown by `~/projects/dev-workspace/bin/dws-termius-setup.sh`.
4. Connect with Tailscale enabled on the phone.
5. Reconnect to work with `~/projects/dev-workspace/bin/dws-sessions.sh reconnect`.

See `docs/termius-setup.md` for the full setup flow.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Monitor down | `systemctl --user restart dws-task-monitor.service` |
| Managed sessions missing | `systemctl --user restart dws-sessions-init.service` |
| Queue looks wrong | inspect `~/projects/dev-workspace/.state/task-queue.json` and compare against `dws-sessions.sh list` |
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

Cron logs still default to `/tmp`. If you want them centralized under
`/var/log/dws`, reinstall the block with:

```bash
DWS_CRON_LOG_DIR=/var/log/dws ~/projects/dev-workspace/bin/dws-cron-setup.sh
```

## Self-Healing Stack

```text
Layer 3: Tailscale + SSH reconnect         -> operator reconnects to an existing session
Layer 2: dws-task-monitor.service          -> relaunches crashed or compacted workers
Layer 1: dws-sessions-init.service         -> recreates the managed tmux pool after boot
```
