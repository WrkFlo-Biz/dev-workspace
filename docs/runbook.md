# Dev Workspace Runbook

Operator runbook for the `dev-workspace-vm` multi-agent environment.

## Quick Reference

| Item | Location / command |
| --- | --- |
| Repo | `~/projects/dev-workspace` |
| Backup root | `~/backups/dev-workspace` |
| Repo wrappers | `~/projects/dev-workspace/bin/` |
| Repo scripts | `~/projects/dev-workspace/scripts/` |
| Managed queue | `~/projects/dev-workspace/.state/task-queue.json` |
| User units | `dws-sessions-init.service`, `dws-task-monitor.service`, `dws-phone-server.service` |
| User-unit installer | `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh` (installs `dws-sessions-init.service` and `dws-task-monitor.service`) |
| Monitor log | `/var/log/dws/monitor.log` |
| Log viewer | `~/projects/dev-workspace/bin/dws-log-viewer.sh` |
| Boot verifier | `~/projects/dev-workspace/bin/dws-boot-verify.sh` |
| Status commands | `~/projects/dev-workspace/bin/dws-status.sh`, `~/projects/dev-workspace/bin/dws-doctor.sh` |
| Update script | `~/projects/dev-workspace/scripts/dws-update.sh` |
| Firewall tool | `~/projects/dev-workspace/bin/dws-firewall.sh` |
| Firewall snapshots | `/var/lib/dws/firewall` |
| SSH baseline (repo) | `~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf` |
| Live SSH drop-in | `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf` |
| Foundry env | `~/.config/wrkflo/foundry.env` |
| Phone server | `http://127.0.0.1:8081/health` |

## Tailscale Network

| Device | IP |
| --- | --- |
| dev-workspace-vm | `100.117.16.63` |
| Mac | `100.78.207.22` |
| iPhone | `100.88.249.22` |
| openclaw-gateway | `100.126.194.98` |

## Start

### Start the managed runtime

```bash
systemctl --user start dws-sessions-init.service
systemctl --user start dws-task-monitor.service
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
```

### Install or repair the repo-managed user units

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check || \
  ~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user daemon-reload
systemctl --user enable dws-sessions-init.service dws-task-monitor.service
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
```

### Reattach after a disconnect

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
```

### Launcher recovery if SSH lands at a plain shell

```bash
unset SKIP_LAUNCHER
~/bin/dws-launcher.sh
~/projects/dev-workspace/scripts/dws-launcher.sh status
```

## Stop

### Stop only the monitor loop

```bash
systemctl --user stop dws-task-monitor.service
systemctl --user status dws-task-monitor.service --no-pager
```

### Full stop of monitor plus managed `tmux` sessions

```bash
systemctl --user stop dws-task-monitor.service
~/projects/dev-workspace/bin/dws-sessions.sh kill-all
systemctl --user stop dws-sessions-init.service || true
tmux list-sessions 2>/dev/null || echo "no tmux sessions"
```

### Rebuild after a full stop

```bash
systemctl --user start dws-sessions-init.service
systemctl --user start dws-task-monitor.service
~/projects/dev-workspace/bin/dws-sessions.sh list
```

## Backup

### Create a new backup snapshot

```bash
~/projects/dev-workspace/bin/dws-backup.sh backup
readlink -f ~/backups/dev-workspace/latest
find ~/backups/dev-workspace -maxdepth 1 -type f -name 'dws-backup-*.tar.gz' | sort | tail -3
```

### Verify that the latest backup restores cleanly

```bash
~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest
~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest --prune
```

### Backup plus verify in one command

```bash
~/projects/dev-workspace/bin/dws-backup.sh cron
```

## Restore

### Extract the latest backup into a restore directory

```bash
mkdir -p ~/restore
~/projects/dev-workspace/bin/dws-backup.sh restore latest --target ~/restore
RESTORE_NOTE=$(find ~/restore -maxdepth 2 -name RESTORE.txt -print | sort | tail -1)
printf '%s\n' "$RESTORE_NOTE"
sed -n '1,160p' "$RESTORE_NOTE"
```

### Restore the backed-up home data after extraction

Replace `<archive-root>` with the extracted backup directory name shown by the
restore command.

```bash
mkdir -p ~/.config/wrkflo && cp -a ~/restore/<archive-root>/home/.config/wrkflo/. ~/.config/wrkflo/
mkdir -p ~/bin && cp -a ~/restore/<archive-root>/home/bin/. ~/bin/
mkdir -p ~/.ssh && chmod 700 ~/.ssh && cp -a ~/restore/<archive-root>/home/.ssh/. ~/.ssh/
crontab ~/restore/<archive-root>/system/crontab.txt
```

### Post-restore validation

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check || \
  ~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
~/projects/dev-workspace/bin/dws-cron-setup.sh --check || \
  ~/projects/dev-workspace/bin/dws-cron-setup.sh
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
~/projects/dev-workspace/bin/dws-sessions.sh list
```

## Update

### Update the repo checkout and deployed helpers

```bash
cd ~/projects/dev-workspace
git status --short
git pull --ff-only
~/projects/dev-workspace/scripts/dws-update.sh --dry-run
~/projects/dev-workspace/scripts/dws-update.sh --force
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check || \
  ~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user daemon-reload
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
```

### When the repo has local changes and `dws-update.sh` skips `git pull`

```bash
cd ~/projects/dev-workspace
git status --short
git fetch --all --prune
git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "no upstream configured"
git log --oneline --decorate --max-count=5 HEAD..@{upstream} 2>/dev/null || true
~/projects/dev-workspace/scripts/dws-update.sh --dry-run
```

## Reboot Recovery

Full drill: [`docs/reboot-recovery-test.md`](./reboot-recovery-test.md)

### Quick recovery path from another machine

```bash
ssh moses@dev-workspace-vm 'sudo reboot'
until ssh -o ConnectTimeout=5 -o BatchMode=yes moses@dev-workspace-vm 'uptime -p' 2>/dev/null; do
  sleep 5
done
ssh moses@dev-workspace-vm '~/projects/dev-workspace/bin/dws-boot-verify.sh'
ssh moses@dev-workspace-vm 'systemctl --user status dws-sessions-init.service --no-pager'
ssh moses@dev-workspace-vm 'systemctl --user status dws-task-monitor.service --no-pager'
ssh moses@dev-workspace-vm 'systemctl --user status dws-phone-server.service --no-pager || true'
ssh moses@dev-workspace-vm 'tail -n 20 /var/log/dws/monitor.log'
ssh moses@dev-workspace-vm 'curl -s http://127.0.0.1:8081/health || true'
```

### Quick recovery path when already on the VM

```bash
sudo reboot
# reconnect after 60-90s
~/projects/dev-workspace/bin/dws-boot-verify.sh
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
```

### Post-reboot service checks

```bash
systemctl is-active tailscaled ssh ssh.socket cron
systemctl --user is-active dws-sessions-init.service dws-task-monitor.service
tmux list-sessions
crontab -l | sed -n '/# >>> dev-workspace managed cron >>>/,/# <<< dev-workspace managed cron <<</p'
```

## SSH / Firewall Recovery

### SSH health and safe reload

```bash
systemctl is-active ssh ssh.socket sshd sshd.socket 2>/dev/null || true
ss -tlnp | grep -E '[:.]22[[:space:]]'
sudo sh -c 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -e "$f" ] || continue; echo "--- $f ---"; sed -n "1,160p" "$f"; done'
journalctl -u ssh --since '24 hours ago' --no-pager | tail -n 40
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

### SSH lockout rollback

Keep one working shell open while doing this.

```bash
sudo mv /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf.disabled 2>/dev/null || true
sudo mv /etc/ssh/sshd_config.d/zz-dws-hardening.conf /etc/ssh/sshd_config.d/zz-dws-hardening.conf.disabled 2>/dev/null || true
sudo mv /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf.disabled 2>/dev/null || true
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

### Reinstall the repo SSH baseline after access is back

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo install -m 0644 \
  ~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf \
  /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

### Firewall preview, apply, verify, rollback

```bash
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run
sudo ~/projects/dev-workspace/bin/dws-firewall.sh
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback
```

### Force a specific firewall backend

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify --backend ufw
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback --backend ufw

sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend iptables
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --verify --backend iptables
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --rollback --backend iptables
```

### Inspect firewall snapshots and current access paths

```bash
ls -l /var/lib/dws/firewall/latest /var/lib/dws/firewall/latest-ufw /var/lib/dws/firewall/latest-iptables 2>/dev/null || true
sudo ufw status verbose 2>/dev/null || true
sudo iptables -S 2>/dev/null | sed -n '1,120p'
~/projects/dev-workspace/bin/dws-connect-test.sh
tailscale status
ssh -o ConnectTimeout=5 moses@dev-workspace-vm 'printf ssh-ok\n'
ssh -o ConnectTimeout=5 moses@100.117.16.63 'printf ssh-ok\n'
```

## Phone Access

### Print the current Termius host settings

```bash
~/projects/dev-workspace/bin/dws-termius-setup.sh
ls -l ~/.ssh/termius_20260415 ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null
```

### Termius reconnect path after a phone sleep or network drop

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
```

### Phone server health and recovery

```bash
systemctl --user status dws-phone-server.service --no-pager
journalctl --user -u dws-phone-server.service -n 40 --no-pager
curl -sS http://127.0.0.1:8081/health
curl -sS http://127.0.0.1:8081/results
systemctl --user restart dws-phone-server.service
```

### Queue a phone action from the VM with exact HTTP calls

```bash
curl -sS -X POST http://127.0.0.1:8081/queue \
  -H 'Content-Type: application/json' \
  -d '{"action":"notify","title":"ALERT","body":"prod 500s"}'

curl -sS -X POST http://127.0.0.1:8081/queue \
  -H 'Content-Type: application/json' \
  -d '{"action":"open_url","url":"https://github.com/Wrk-Flo/dev-workspace"}'

curl -sS -X POST http://127.0.0.1:8081/queue \
  -H 'Content-Type: application/json' \
  -d '{"action":"speak","text":"Moses, coffee is ready"}'

curl -sS -X POST http://127.0.0.1:8081/queue \
  -H 'Content-Type: application/json' \
  -d '{"action":"copy","text":"API_KEY_abcdef123"}'

curl -sS http://127.0.0.1:8081/results
```

### Tailnet reachability checks for Mac and iPhone

```bash
tailscale ping 100.78.207.22
tailscale ping 100.88.249.22
~/projects/dev-workspace/bin/dws-connect-test.sh
```

## Monitor Management

### Check monitor state, logs, and queue health

```bash
systemctl --user status dws-task-monitor.service --no-pager
journalctl --user -u dws-task-monitor.service -n 40 --no-pager
tail -n 40 /var/log/dws/monitor.log
~/projects/dev-workspace/bin/dws-log-viewer.sh --since '30 minutes ago' --grep 'FAIL|ERROR|ALERT'
sed -n '1,220p' ~/projects/dev-workspace/.state/task-queue.json
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
```

### Start, stop, and restart the monitor

```bash
systemctl --user start dws-task-monitor.service
systemctl --user stop dws-task-monitor.service
systemctl --user restart dws-task-monitor.service
```

### Rebuild the runtime when the monitor looks stale

```bash
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
```

### Follow the monitor log live

```bash
~/projects/dev-workspace/bin/dws-log-viewer.sh --follow
```

### Queue counts and active assignments

```bash
jq -r '
  (.tasks // []) as $tasks
  | "pending=\($tasks | map(select(.status == \"pending\")) | length)"
  , "in_progress=\($tasks | map(select(.status == \"in_progress\")) | length)"
  , "completed=\($tasks | map(select(.status == \"completed\")) | length)"
' ~/projects/dev-workspace/.state/task-queue.json

jq -r '.tasks[]? | select(.status == "in_progress") | [.id, .assigned, .repo] | @tsv' \
  ~/projects/dev-workspace/.state/task-queue.json
```

## Cron

### Inspect and repair the repo-managed cron block

```bash
crontab -l | sed -n '/# >>> dev-workspace managed cron >>>/,/# <<< dev-workspace managed cron <<</p'
~/projects/dev-workspace/bin/dws-cron-setup.sh --show
~/projects/dev-workspace/bin/dws-cron-setup.sh --check
~/projects/dev-workspace/bin/dws-cron-setup.sh
```
