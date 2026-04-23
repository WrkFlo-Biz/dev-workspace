# Dev Workspace Runbook

Operational procedures for the dev-workspace-vm multi-agent environment.

## Quick Reference

| Item | Location |
|------|----------|
| Repo | ~/projects/dev-workspace |
| Scripts (canonical) | ~/projects/dev-workspace/scripts/ |
| Bin (wrappers) | ~/projects/dev-workspace/bin/ |
| VM-only scripts | ~/bin/ |
| Task queue | ~/projects/dev-workspace/.state/task-queue.json |
| Monitor log | /var/log/dws/monitor.log |
| Health check | ~/bin/dws-boot-verify.sh |
| Systemd services | ~/.config/systemd/user/dws-*.service |
| SSH hardening | /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf |
| Foundry env | ~/.config/wrkflo/foundry.env |

## Tailscale Network

| Device | IP |
|--------|-----|
| dev-workspace-vm | 100.117.16.63 |
| Mac | 100.78.207.22 |
| iPhone | 100.88.249.22 |
| openclaw-gateway | 100.126.194.98 |

## Start / Resume

### After reboot (automatic)
The systemd services handle startup automatically:
1. `dws-sessions-init.service` creates all 9 tmux sessions
2. `dws-task-monitor.service` starts the monitor loop

Verify with:
```bash
bash ~/bin/dws-boot-verify.sh
```

### Manual start (if needed)
```bash
# Start sessions
bash ~/bin/dws-sessions-init.sh

# Start monitor
systemctl --user start dws-task-monitor.service

# Or in tmux (fallback)
tmux new-session -d -s monitor 'bash ~/bin/task-monitor.sh'
```

## Stop

### Graceful stop (keep sessions)
```bash
systemctl --user stop dws-task-monitor.service
```

### Full stop (kill all sessions)
```bash
systemctl --user stop dws-task-monitor.service
for s in dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h orchestrator; do
  tmux kill-session -t $s 2>/dev/null
done
```

## Monitor Management

### Check status
```bash
systemctl --user status dws-task-monitor.service
tail -20 /var/log/dws/monitor.log
```

### Restart monitor
```bash
systemctl --user restart dws-task-monitor.service
```

### View live log
```bash
tail -f /var/log/dws/monitor.log
```

## Task Queue

### Check queue
```bash
python3 -c "import json; d=json.load(open('$HOME/projects/dev-workspace/.state/task-queue.json')); p=sum(1 for t in d['tasks'] if t['status']=='pending'); i=sum(1 for t in d['tasks'] if t['status']=='in_progress'); c=sum(1 for t in d['tasks'] if t['status']=='completed'); print(f'pending={p} in_progress={i} completed={c}')"
```

### Add a task manually
```bash
python3 -c "import json; d=json.load(open('$HOME/projects/dev-workspace/.state/task-queue.json')); d['tasks'].append({'id':'manual-001','phase':7,'repo':'dev-workspace','description':'YOUR TASK HERE','assigned':None,'status':'pending'}); json.dump(d,open('$HOME/projects/dev-workspace/.state/task-queue.json','w'),indent=2)"
```

## tmux Sessions

### List sessions
```bash
tmux list-sessions
```

### Attach to a session
```bash
tmux attach-session -t dws-a
# Detach: Ctrl+B then D
```

### Check what a worker is doing
```bash
tmux capture-pane -t worker-c -p | tail -10
```

## SSH

### Current config
```bash
cat /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
```

### Test config before reload
```bash
sudo sshd -t
```

### Reload SSH (keeps active connections)
```bash
sudo systemctl reload ssh
```

### SSH lockout recovery
If locked out via SSH:
1. Use Azure Portal serial console
2. Restore backup: `sudo cp /tmp/99-wrkflo-hardening.conf.bak /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf`
3. `sudo systemctl reload ssh`

## Backup

```bash
bash ~/projects/dev-workspace/scripts/dws-backup.sh
```

## Restore

```bash
bash ~/projects/dev-workspace/scripts/dws-backup.sh --restore <backup-file>
```

## Update Scripts

```bash
cd ~/projects/dev-workspace && git pull
```

## Reboot Recovery

Full procedure in docs/reboot-recovery-test.md. Quick version:
```bash
sudo reboot
# Wait 60-90s
ssh dev-workspace-vm 'bash ~/bin/dws-boot-verify.sh'
```

## Phone / Termius Access

1. Install Termius on iPhone
2. Add host: IP=100.117.16.63, port=22, user=moses
3. Import SSH key (ed25519 labeled termius-20260415)
4. Connect — requires Tailscale active on phone
5. Run `tmux attach-session -t orchestrator` to view work

See docs/termius-setup.md for detailed steps.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Worker stuck | Monitor auto-detects after 2 cycles and relaunches |
| Worker compacted | Monitor relaunches automatically |
| SSH dropped (Mac) | Reconnect agent restores within 30s |
| SSH dropped (phone) | Manual reconnect in Termius |
| Monitor down | `systemctl --user start dws-task-monitor` |
| No tmux sessions | `bash ~/bin/dws-sessions-init.sh` |
| Queue empty | Monitor auto-refills when pending < 3 |
| Can't push to git | Check OAuth token scope — may need workflow scope for .github/ files |
| Firewall locked out | Use Azure serial console, `sudo ufw disable` |

## Cron Jobs

```
*/15 * * * *  dws-health-check.sh    # periodic health check
 30  2 * * *  dws-cleanup.sh         # daily log rotation
  0  4 * * *  dws-cleanup.sh         # daily dead session cleanup
```

## Self-Healing Stack

```
Layer 3: Mac Reconnect Agent (30s)  — SSH drops → reconnect Terminal windows
Layer 2: VM Task Monitor (30s)      — Codex crashes → relaunch + redispatch
Layer 1: SSH Keepalive (30s)        — Prevent connection drops
```
