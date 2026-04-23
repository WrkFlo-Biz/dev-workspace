# Script Layout

## Convention

- **scripts/** is the canonical source for all shell scripts
- **bin/** contains thin wrappers that exec into scripts/ — never edit bin/ directly
- **~/bin/** on the VM contains operational scripts that are NOT part of the repo (task-monitor.sh, sync-status.py, etc.)

## Wrapper pattern (bin/)

Every file in bin/ follows this pattern:

```bash
#!/usr/bin/env bash
exec "$(dirname "$0")/../scripts/<name>.sh" "$@"
```

## Adding a new script

1. Create the script in scripts/
2. Make it executable: chmod +x scripts/new-script.sh
3. Create a wrapper in bin/ using the pattern above
4. If the script needs to run on the VM outside the repo, symlink ~/bin/new-script.sh -> ~/projects/dev-workspace/scripts/new-script.sh

## Current inventory

### scripts/ (canonical)
- dws-backup.sh — Backup and restore VM state
- dws-cleanup.sh — Clean worktrees, logs, dead sessions
- dws-connect-test.sh — Connectivity test to Tailscale peers
- dws-cron-setup.sh — Managed cron installer
- dws-doctor.sh — Workspace diagnostic tool
- dws-firewall.sh — UFW firewall configuration
- dws-health-full.sh — Comprehensive VM health check
- dws-health.sh — Health check suite
- dws-health-check.sh — Cron health check
- dws-launcher.sh — Interactive session launcher
- dws-motd.sh — Login message-of-the-day
- dws-sessions.sh — tmux session manager
- dws-sessions-init.sh — Boot all tmux sessions
- dws-status.sh — Quick status overview
- dws-sync-mac.sh — Sync configs/scripts to Mac
- dws-tailscale-diag.sh — Tailscale diagnostics
- dws-termius-setup.sh — Termius config helper
- vm-setup.sh — Full VM provisioning
- vm-bootstrap.sh — Bootstrap essentials

### ~/bin/ (VM-only, not in repo)
- task-monitor.sh — Autonomous task monitor (systemd service)
- dws-boot-verify.sh — Post-reboot verification
- dws-sessions-init.sh — Session init (systemd service)
- sync-status.py — Monitor status JSON writer
- task-planner.py — Task queue planner
