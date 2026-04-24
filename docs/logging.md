# Centralized Logging

This document records the logging layout as audited on 2026-04-23.

`/var/log/dws` is the intended central log directory, but the VM is only
partially migrated and the repo-owned/runtime-owned boundary matters:

- the live task queue is
  `~/projects/dev-workspace/.state/task-queue.json`
- optional host-local monitors can still write `/var/log/dws/monitor.log`
- several health, cron, planner, and legacy artifacts still live under `/tmp`
- some service output only exists in `journald`

One important constraint: this repo no longer installs a repo-managed
`dws-task-monitor.service`. If a host still runs `~/bin/task-monitor.sh`, treat
it as host-local runtime drift. The repo keeps `scripts/task-monitor.sh` as a
source snapshot and compatibility reference, not as a current repo-owned unit
entrypoint.

## `/var/log/dws` Layout

The live directory can still contain `monitor.log`, but that file now belongs
to optional host-local monitor setups rather than the checked-in repo-managed
unit set.

| Path | Producer / owner | Live on this VM | Notes |
| --- | --- | --- | --- |
| `/var/log/dws/` | `bin/dws-systemd-user-setup.sh install` | yes | Created with owner `$USER:$(id -gn)` and mode `0775`. `bin/dws-boot-verify.sh` treats it as required boot-time state. |
| `/var/log/dws/monitor.log` | optional host-local `~/bin/task-monitor.sh` | host-dependent | Only present when a host-local monitor is still installed. |
| `/var/log/dws/health-check.log` | `scripts/dws-cron-setup.sh` managed cron block | not currently | The tracked installer now defaults this cron capture log into `/var/log/dws`, but the currently installed crontab on this VM still writes to `/tmp/dws-health-check.cron.log`. |
| `/var/log/dws/log-rotate.log` | `scripts/dws-cron-setup.sh` managed cron block | not currently | Same drift as above. The tracked installer would prefer `scripts/dws-rotate-logs.sh`, but the live crontab still logs a fallback `dws-cleanup.sh` job to `/tmp/dws-log-rotate.cron.log`. |
| `/var/log/dws/session-cleanup.log` | `scripts/dws-cron-setup.sh` managed cron block | not currently | Same drift as above; the live crontab still writes to `/tmp/dws-session-cleanup.cron.log`. |
| `/var/log/dws/*.YYYYMMDDTHHMMSSZ.gz` | `scripts/dws-rotate-logs.sh` | none present now | Timestamped gzip archives created when the rotate script runs. The script keeps the four most recent archives per active log by default. |

## Current VM Log Sources

### `/var/log/dws`

| Path | Producer | Main readers / dependents | Notes |
| --- | --- | --- | --- |
| `/var/log/dws/monitor.log` | optional host-local `~/bin/task-monitor.sh` | `docs/runbook.md`, `docs/troubleshooting.md`, `docs/reboot-recovery-test.md`, operators tailing the monitor directly | This is runtime-specific and should not be treated as a repo-owned unit guarantee. |

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
| `~/projects/dev-workspace/.state/task-queue.json` | repo-owned orchestration state, optionally read or updated by host-local runtime | runbooks, troubleshooting, direct queue inspection | This is the verified repo-owned live task queue path on the VM. |
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

The tracked repo-owned user units in `config/systemd-user/` do not set
`StandardOutput=` or `StandardError=`. Optional host-local services also leave
stdout/stderr in the user journal unless they manage their own file logs.

| Unit | Primary log surface | Notes |
| --- | --- | --- |
| `dws-sessions-init.service` | `journalctl --user -u dws-sessions-init.service` | No file log is configured in the tracked unit. |
| `dws-safe-mode.service` | `journalctl --user -u dws-safe-mode.service` | No file log is configured in the tracked unit. |
| optional host-local `dws-task-monitor.service` | `journalctl --user -u dws-task-monitor.service` plus `/var/log/dws/monitor.log` | Present only on hosts that still install the legacy monitor path. |
| `dws-phone-server.service` | `journalctl --user -u dws-phone-server.service` | Host-local phone-control unit. `~/bin/dws-phone-server.py` prints startup logs to stdout and request logs to stderr via `log_message()`. This repo does not provision the unit. |
| `wrkflo-orchestrator-api.service` | `journalctl --user -u wrkflo-orchestrator-api.service` | Host-local or sibling-repo unit that runs the local API on `127.0.0.1:8100`; no file log path is configured by this repo. |

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
tail -n 40 /var/log/dws/health-check.log /var/log/dws/log-rotate.log /var/log/dws/session-cleanup.log 2>/dev/null || true
tail -n 40 /tmp/dws-health.log /tmp/dws-health-alerts.log
tail -n 40 /tmp/dws-health-check.cron.log /tmp/dws-log-rotate.cron.log /tmp/dws-session-cleanup.cron.log 2>/dev/null || true
sed -n '1,120p' ~/projects/dev-workspace/.state/task-queue.json
journalctl --user -u dws-task-monitor.service -u dws-phone-server.service -u wrkflo-orchestrator-api.service -n 50 --no-pager
```

## Practical Takeaway

The authoritative repo-owned surfaces on 2026-04-24 are:

1. `~/projects/dev-workspace/.state/task-queue.json` for live queue state.
2. `journald` for repo-managed user services such as `dws-sessions-init.service`
   and `dws-safe-mode.service`.
3. `/tmp` for health-check logs, installed cron capture logs, planner artifacts,
   alert spools, and several legacy paths still referenced by repo tooling.
4. `/var/log/dws/monitor.log` only when an optional host-local monitor is still
   installed on that VM.

Treat the current state as a partial migration toward `/var/log/dws`, not a
fully centralized logging setup.
