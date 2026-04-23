# Centralized Logging

This document records the logging layout as audited on 2026-04-23.

`/var/log/dws` is the intended central log directory, but the VM is only
partially migrated:

- the live task monitor writes `/var/log/dws/monitor.log`
- the live task queue is
  `~/projects/dev-workspace/.state/task-queue.json`
- several health, cron, planner, and legacy artifacts still live under `/tmp`
- some service output only exists in `journald`

One important constraint: the task monitor entrypoint is `~/bin/task-monitor.sh`
on the VM, not a tracked file in this repo. The repo wires it into systemd, and
the live host confirms that it writes `/var/log/dws/monitor.log` and updates
`~/projects/dev-workspace/.state/task-queue.json`.

## `/var/log/dws` Layout

The live directory currently contains only `monitor.log`, but the tracked repo
now expects more of the centralized logging story to land here.

| Path | Producer / owner | Live on this VM | Notes |
| --- | --- | --- | --- |
| `/var/log/dws/` | `bin/dws-systemd-user-setup.sh install` | yes | Created with owner `$USER:$(id -gn)` and mode `0775`. `bin/dws-boot-verify.sh` treats it as required boot-time state. |
| `/var/log/dws/monitor.log` | `~/bin/task-monitor.sh` via `dws-task-monitor.service` | yes | Authoritative cycle log for the live task monitor. |
| `/var/log/dws/dws-health-check.cron.log` | `scripts/dws-cron-setup.sh` managed cron block | not currently | The tracked installer defaults this cron capture log into `/var/log/dws`, but the currently installed crontab on this VM still writes to `/tmp/dws-health-check.cron.log`. |
| `/var/log/dws/dws-log-rotate.cron.log` | `scripts/dws-cron-setup.sh` managed cron block | not currently | Same drift as above. The tracked installer would prefer `scripts/dws-rotate-logs.sh`, but the live crontab still logs a fallback `dws-cleanup.sh` job to `/tmp/dws-log-rotate.cron.log`. |
| `/var/log/dws/dws-session-cleanup.cron.log` | `scripts/dws-cron-setup.sh` managed cron block | not currently | Same drift as above; the live crontab still writes to `/tmp/dws-session-cleanup.cron.log`. |
| `/var/log/dws/*.YYYYMMDDTHHMMSSZ.gz` | `scripts/dws-rotate-logs.sh` | none present now | Timestamped gzip archives created when the rotate script runs. The script keeps the four most recent archives per active log by default. |

## Current VM Log Sources

### `/var/log/dws`

| Path | Producer | Main readers / dependents | Notes |
| --- | --- | --- | --- |
| `/var/log/dws/monitor.log` | live `~/bin/task-monitor.sh` | `docs/runbook.md`, `docs/troubleshooting.md`, `docs/reboot-recovery-test.md`, operators tailing the monitor directly | This is the only confirmed live file log under `/var/log/dws` on 2026-04-23. |

### `/tmp` file logs on the VM

| Path | Producer | Main readers / dependents | Notes |
| --- | --- | --- | --- |
| `/tmp/dws-health.log` | `scripts/dws-health-check.sh` | `scripts/dws-launcher.sh`, `scripts/dws-status.sh`, `scripts/dws-log.sh` | Periodic health summary log. |
| `/tmp/dws-health-alerts.log` | `scripts/dws-health-check.sh` | `scripts/dws-launcher.sh`, `scripts/dws-log.sh`, `scripts/dws-notify.sh` | Alert-only companion log. |
| `/tmp/dws-health-check.cron.log` | current live crontab | operator troubleshooting | Stdout/stderr for the installed health-check cron job. This is live-host drift from the tracked `scripts/dws-cron-setup.sh` default. |
| `/tmp/dws-log-rotate.cron.log` | current live crontab | `scripts/dws-doctor.sh`, operator troubleshooting | Stdout/stderr for the installed `dws-log-rotate` cron slot. The live crontab still runs `scripts/dws-cleanup.sh` as a fallback here. |
| `/tmp/dws-session-cleanup.cron.log` | current live crontab | `scripts/dws-doctor.sh`, operator troubleshooting | Stdout/stderr for the installed session-cleanup cron job. |
| `/tmp/monitor-log.txt` | no live producer confirmed on this VM | `scripts/dws-sessions.sh`, `scripts/dws-doctor.sh` | Legacy monitor-log path still used as a default reader by some repo scripts. The live monitor writes `/var/log/dws/monitor.log` instead. |
| `/tmp/planner-log.txt` | external planner runtime, not tracked here | `scripts/dws-doctor.sh`, `scripts/dws-status.sh` | The repo checks freshness, but does not define the writer. |
| `/tmp/orchestrator-monitor.log` | external orchestrator monitor/runtime, not tracked here | `scripts/dws-doctor.sh`, `docs/troubleshooting.md` | Freshness is checked by `scripts/dws-doctor.sh`; no writer is tracked here. |
| `/tmp/dws-sync-all.out.log` | no tracked producer found in this repo snapshot | `scripts/dws-log.sh` | Treat this as legacy or operator-created unless a host-local wrapper is writing it. |

### Runtime state and status artifacts outside `/var/log/dws`

These are not logs, but operators will run into them while troubleshooting the
same services.

| Path | Producer | Main readers / dependents | Notes |
| --- | --- | --- | --- |
| `~/projects/dev-workspace/.state/task-queue.json` | live `~/bin/task-monitor.sh` | runbooks, troubleshooting, direct queue inspection | This is the verified live task queue path on the VM. |
| `/tmp/dws-cleanup.last-success` | `scripts/dws-cleanup.sh` | `scripts/dws-doctor.sh` | Written after successful cleanup runs. |
| `/tmp/monitor-status.json` | no live producer confirmed on this VM | `scripts/dws-doctor.sh` | Legacy monitor-status path still referenced by repo tooling. |
| `/tmp/task-queue.json` | legacy default still assumed by some repo scripts | `scripts/dws-launcher.sh`, `scripts/dws-status.sh`, `scripts/dws-motd.sh` | Not the verified live queue path. |
| `/tmp/planner-status.md` | external planner runtime, not tracked here | `scripts/dws-doctor.sh`, `scripts/dws-status.sh` | Freshness is checked, writer is not tracked. |
| `/tmp/planner-state.json` | external planner runtime, not tracked here | `scripts/dws-doctor.sh`, `scripts/dws-status.sh` | Freshness is checked, writer is not tracked. |
| `/tmp/dws-alerts.txt` | `scripts/dws-notify.sh` | `scripts/dws-notify.sh check` | Alert spool, not a structured log. |
| `/tmp/dws-alerts.read` | `scripts/dws-notify.sh` | `scripts/dws-notify.sh check` / `clear` | Read cursor for the alert spool. |

### Mac-side logs referenced by this repo

These are relevant to the overall workspace, but they are not part of the VM's
`/var/log/dws` tree.

| Path | Producer | Notes |
| --- | --- | --- |
| `/tmp/socat-*.log` | `mac-setup/mac-bridges.sh` and `mac-setup/chrome-cdp.sh` | Bridge logs on the Mac side. |
| `/tmp/mac-bridges.out.log` | `mac-setup/com.wrkflo.mac-bridges.plist` | Tailed by `scripts/dws-log.sh`. |
| `/tmp/mac-bridges.err.log` | `mac-setup/com.wrkflo.mac-bridges.plist` | Error companion to `mac-bridges.out.log`. |
| `/tmp/chrome-cdp.launchagent.log` | `mac-setup/com.wrkflo.chrome-cdp.plist` | Mac LaunchAgent stdout. |
| `/tmp/chrome-cdp.launchagent.err` | `mac-setup/com.wrkflo.chrome-cdp.plist` | Mac LaunchAgent stderr. |

## Journald-Backed Service Output

The tracked user units in `config/systemd-user/` do not set
`StandardOutput=` or `StandardError=`. The host-local phone server and
orchestrator API units also leave stdout/stderr in the user journal.

| Unit | Primary log surface | Notes |
| --- | --- | --- |
| `dws-sessions-init.service` | `journalctl --user -u dws-sessions-init.service` | No file log is configured in the tracked unit. |
| `dws-task-monitor.service` | `journalctl --user -u dws-task-monitor.service` plus `/var/log/dws/monitor.log` | The unit launches `~/bin/task-monitor.sh`, which also writes its own file log. |
| `dws-phone-server.service` | `journalctl --user -u dws-phone-server.service` | `~/bin/dws-phone-server.py` prints startup logs to stdout and request logs to stderr via `log_message()`. |
| `wrkflo-orchestrator-api.service` | `journalctl --user -u wrkflo-orchestrator-api.service` | Runs the local API on `127.0.0.1:8100`; no file log path is configured. |

## Retention And Cleanup

- `scripts/dws-cleanup.sh` only manages `${DWS_TMPDIR:-/tmp}` by default.
- `scripts/dws-cleanup.sh` compresses `dws-*.log`, `socat-*.log`, and
  `mac-bridges.out.log` after 2 days and removes matching files after 7 days.
- `scripts/dws-rotate-logs.sh` manages `/var/log/dws`: it rotates active files
  into timestamped gzip archives and keeps the four most recent archives per log
  by default.
- The tracked `scripts/dws-cron-setup.sh` now defaults cron capture logs to
  `/var/log/dws` and prefers `dws-rotate-logs.sh` when that script is
  available.
- The currently installed crontab on this VM predates that layout: it still
  writes its three cron capture logs to `/tmp` and still uses the
  `dws-cleanup.sh` fallback in the `dws-log-rotate` slot.

## Quick Inspection Commands

```bash
ls -lah /var/log/dws
tail -n 50 /var/log/dws/monitor.log
crontab -l | sed -n '/# >>> dev-workspace managed cron >>>/,/# <<< dev-workspace managed cron <<</p'
tail -n 40 /tmp/dws-health.log /tmp/dws-health-alerts.log
tail -n 40 /tmp/dws-health-check.cron.log /tmp/dws-log-rotate.cron.log /tmp/dws-session-cleanup.cron.log
sed -n '1,120p' ~/projects/dev-workspace/.state/task-queue.json
journalctl --user -u dws-task-monitor.service -u dws-phone-server.service -u wrkflo-orchestrator-api.service -n 50 --no-pager
```

## Practical Takeaway

The authoritative live surfaces on 2026-04-23 are:

1. `/var/log/dws/monitor.log` for the task-monitor cycle log.
2. `~/projects/dev-workspace/.state/task-queue.json` for live queue state.
3. `/tmp` for health-check logs, installed cron capture logs, planner artifacts,
   alert spools, and several legacy paths still referenced by repo tooling.
4. `journald` for service stdout/stderr when the process does not manage its own
   file log.

Treat the current state as a partial migration toward `/var/log/dws`, not a
fully centralized logging setup.
