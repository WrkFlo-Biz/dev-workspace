# Centralized Logging

This document records the logging and runtime-artifact layout implied by the
tracked repo as audited on 2026-04-23. The live monitor now writes
`/var/log/dws/monitor.log`, and the live task queue lives in
`~/projects/dev-workspace/.state/task-queue.json`, but centralization is still
partial because several repo tools continue to default to `/tmp` and some
service output still lives in `journald`.

One important constraint: the task monitor entrypoint is `~/bin/task-monitor.sh`,
which is VM-local and not tracked in this repo. The repo wires that script into
systemd and several docs refer to its logs, but the script itself must be
verified on the live host.

## `/var/log/dws` Today

The repo-managed pieces that currently reference `/var/log/dws` are:

| Path | Producer / source | Where it is wired | Rotation / cleanup in repo | Notes |
| --- | --- | --- | --- | --- |
| `/var/log/dws/` | `bin/dws-systemd-user-setup.sh install` | Creates the directory, sets owner to `$USER:$(id -gn)`, mode `0775`, then installs the user units | None found | `bin/dws-boot-verify.sh` treats this directory as required boot-time state and reports how many entries it contains. |
| `/var/log/dws/monitor.log` | `~/bin/task-monitor.sh` when launched by `dws-task-monitor.service` | `config/systemd-user/dws-task-monitor.service` runs `%h/bin/task-monitor.sh`; `docs/runbook.md`, `docs/troubleshooting.md`, and `docs/reboot-recovery-test.md` tail this file | None found | Verified on-host from the live monitor script. Treat this as the authoritative monitor cycle log path. |

## Sources That Can Target `/var/log/dws`, But Do Not By Default

`scripts/dws-cron-setup.sh` renders the managed crontab with:

```bash
LOG_DIR="${DWS_CRON_LOG_DIR:-/tmp}"
```

That means the managed cron jobs only write into `/var/log/dws` if
`DWS_CRON_LOG_DIR=/var/log/dws` is set before installing the crontab block.
Without that override, these files land in `/tmp`.

| Path if redirected into `/var/log/dws` | Current default path | Producer | Rotation / cleanup in repo | Notes |
| --- | --- | --- | --- | --- |
| `/var/log/dws/dws-health-check.cron.log` | `/tmp/dws-health-check.cron.log` | Managed cron entry that runs `dws-health-check.sh` every 15 minutes | If left in `/tmp`, `scripts/dws-cleanup.sh` compresses `dws-*.log` after 2 days and removes them after 7 days. No `/var/log/dws` cleanup is wired by default. | The health check itself also writes `/tmp/dws-health.log` and `/tmp/dws-health-alerts.log`. |
| `/var/log/dws/dws-log-rotate.cron.log` | `/tmp/dws-log-rotate.cron.log` | Managed cron entry tagged `dws-log-rotate` | Same as above | The cron setup script expects a `dws-rotate-logs.sh` target, but that script is not present in this repo snapshot. |
| `/var/log/dws/dws-session-cleanup.cron.log` | `/tmp/dws-session-cleanup.cron.log` | Managed cron entry that runs `dws-cleanup.sh --session-hours ... --log-days ... --temp-days ...` | Same as above | `scripts/dws-doctor.sh` uses this file as a fallback signal when `/tmp/dws-cleanup.last-success` is missing. |

## Logs Still Living Under `/tmp`

### VM-side log files

| Path | Producer | Main readers / dependents | Rotation / cleanup in repo | Notes |
| --- | --- | --- | --- | --- |
| `/tmp/dws-health.log` | `scripts/dws-health-check.sh` | `scripts/dws-launcher.sh`, `scripts/dws-status.sh`, `scripts/dws-log.sh` | `scripts/dws-cleanup.sh` compresses `dws-*.log` after 2 days and removes them after 7 days in `${DWS_TMPDIR:-/tmp}` | Periodic summary log for disk, memory, key, Tailscale, Mac reachability, and repo checks. |
| `/tmp/dws-health-alerts.log` | `scripts/dws-health-check.sh` | `scripts/dws-launcher.sh`, `scripts/dws-log.sh` | Same as above | Alert-only companion log. `dws-health-check.sh` also calls `scripts/dws-notify.sh` when alerts fire. |
| `/tmp/dws-health-check.cron.log` | Managed cron block from `scripts/dws-cron-setup.sh` | Operator troubleshooting | Same as above | Stdout/stderr capture for the health-check cron run. |
| `/tmp/dws-log-rotate.cron.log` | Managed cron block from `scripts/dws-cron-setup.sh` | `scripts/dws-doctor.sh`, operator troubleshooting | Same as above | Captures the `dws-log-rotate` cron entry. The referenced `dws-rotate-logs.sh` script is not tracked here. |
| `/tmp/dws-session-cleanup.cron.log` | Managed cron block from `scripts/dws-cron-setup.sh` | `scripts/dws-doctor.sh`, operator troubleshooting | Same as above | Captures the `dws-session-cleanup` cron entry. |
| `/tmp/monitor-log.txt` | No live producer confirmed on this VM | `scripts/dws-sessions.sh`, `scripts/dws-doctor.sh`, older troubleshooting notes | None found | Treat this as a legacy path that still appears in repo tooling. The verified live monitor log is `/var/log/dws/monitor.log`. |
| `/tmp/planner-log.txt` | External planner runtime, not tracked here | `scripts/dws-doctor.sh`, `scripts/dws-status.sh`, `docs/troubleshooting.md` | None found | The repo monitors freshness, but does not define the writer. |
| `/tmp/orchestrator-monitor.log` | External orchestrator monitor/runtime, not tracked here | `scripts/dws-doctor.sh`, `docs/troubleshooting.md` | None found | Freshness is checked by `scripts/dws-doctor.sh`; no writer is tracked here. |
| `/tmp/dws-sync-all.out.log` | No tracked producer found in this repo snapshot | `scripts/dws-log.sh` | None found | `dws-log.sh` still tails this file, so treat it as a legacy or operator-created log path unless a host-local wrapper is writing it. |

### Runtime state and status files outside `/var/log/dws`

These are not logs, but they are part of the same operator workflow and are
easy to confuse with the centralized log tree.

| Path | Producer | Main readers / dependents | Cleanup / retention in repo | Notes |
| --- | --- | --- | --- | --- |
| `~/projects/dev-workspace/.state/task-queue.json` | live `~/bin/task-monitor.sh` | operator runbooks, troubleshooting, direct queue inspection | None found | This is the verified live queue path on the VM. |
| `/tmp/dws-cleanup.last-success` | `scripts/dws-cleanup.sh` after a non-dry-run success | `scripts/dws-doctor.sh` | Overwritten on each successful cleanup run | This is the preferred cleanup success signal. |
| `/tmp/monitor-status.json` | No live producer confirmed on this VM | `scripts/dws-doctor.sh`, older troubleshooting notes | None found | Legacy artifact path still referenced by some repo tooling, but not confirmed as a current task-monitor output. |
| `/tmp/task-queue.json` | Legacy default still assumed by some repo scripts | `scripts/dws-launcher.sh`, `scripts/dws-status.sh`, `scripts/dws-motd.sh` | None found | Not the verified live queue path. The current service-managed monitor uses `~/projects/dev-workspace/.state/task-queue.json`. |
| `/tmp/planner-status.md` | External planner runtime, not tracked here | `scripts/dws-doctor.sh`, `scripts/dws-status.sh` | None found | Freshness is checked, writer is not tracked. |
| `/tmp/planner-state.json` | External planner runtime, not tracked here | `scripts/dws-doctor.sh`, `scripts/dws-status.sh` | None found | Freshness is checked, writer is not tracked. |
| `/tmp/dws-alerts.txt` | `scripts/dws-notify.sh` | `scripts/dws-notify.sh check` | None found | Alert spool, not a structured log. |
| `/tmp/dws-alerts.read` | `scripts/dws-notify.sh` | `scripts/dws-notify.sh check` / `clear` | None found | Read cursor for the alert spool. |

### Mac-side `/tmp` logs referenced by this repo

These are relevant to the repo, but they are not part of the VM's
`/var/log/dws` tree.

| Path | Producer | Rotation / cleanup in repo | Notes |
| --- | --- | --- | --- |
| `/tmp/socat-*.log` | `mac-setup/mac-bridges.sh` and `mac-setup/chrome-cdp.sh` | `scripts/dws-cleanup.sh` compresses and removes `socat-*.log` if it is run against the same `TMP_ROOT` | Bridge logs for the Mac-side port forwards. |
| `/tmp/mac-bridges.out.log` | `mac-setup/com.wrkflo.mac-bridges.plist` | `scripts/dws-cleanup.sh` compresses and removes this file pattern | Tailed by `scripts/dws-log.sh`. |
| `/tmp/mac-bridges.err.log` | `mac-setup/com.wrkflo.mac-bridges.plist` | None found | Error companion to `mac-bridges.out.log`. |
| `/tmp/chrome-cdp.launchagent.log` | `mac-setup/com.wrkflo.chrome-cdp.plist` | None found | LaunchAgent stdout on the Mac. |
| `/tmp/chrome-cdp.launchagent.err` | `mac-setup/com.wrkflo.chrome-cdp.plist` | None found | LaunchAgent stderr on the Mac. |

## Journald-Backed Service Output

The repo-managed user units in `config/systemd-user/` do not set
`StandardOutput=` or `StandardError=`. Unless the underlying script writes its
own file log, stdout/stderr fall back to the user journal.

| Unit | Repo status | Primary log surface | Notes |
| --- | --- | --- | --- |
| `dws-sessions-init.service` | Tracked in `config/systemd-user/` | `journalctl --user -u dws-sessions-init.service` | No file log path is configured in the unit. |
| `dws-task-monitor.service` | Tracked in `config/systemd-user/` | `journalctl --user -u dws-task-monitor.service` plus whatever `~/bin/task-monitor.sh` writes itself | This is why both `journalctl` and `/var/log/dws/monitor.log` may matter. |
| `dws-phone-server.service` | Referenced in docs, but the unit is not tracked here | Usually `journalctl --user -u dws-phone-server.service` | `scripts/dws-phone-server.py` writes startup logs to stdout and request logs to stderr via `log_message()`. |
| `wrkflo-orchestrator-api.service` | Referenced in docs, but the unit is not tracked here | Usually `journalctl --user -u wrkflo-orchestrator-api.service` | No file log path is defined in this repo. |

## Retention And Cleanup Summary

- `scripts/dws-cleanup.sh` only manages `${DWS_TMPDIR:-/tmp}` by default.
- Its log cleanup targets are `dws-*.log`, `socat-*.log`, and
  `mac-bridges.out.log`.
- By default it compresses matching logs older than 2 days and removes matching
  logs older than 7 days.
- It does not target `monitor-log.txt`, `orchestrator-monitor.log`,
  `planner-log.txt`, `mac-bridges.err.log`, or the Chrome CDP LaunchAgent logs.
- No tracked `logrotate` configuration or repo-managed retention job was found
  for `/var/log/dws`.
- The managed cron block includes a `dws-log-rotate` entry, but the referenced
  `dws-rotate-logs.sh` script is not present in this repo snapshot.

## Quick Troubleshooting Commands

Check the centralized log directory and the monitor log path the newer docs
expect:

```bash
ls -lah /var/log/dws
tail -n 50 /var/log/dws/monitor.log
journalctl --user -u dws-task-monitor.service -n 50 --no-pager
```

Check what the current managed cron block is actually writing:

```bash
crontab -l | sed -n '/# >>> dev-workspace managed cron >>>/,/# <<< dev-workspace managed cron <<</p'
tail -n 40 /tmp/dws-health-check.cron.log /tmp/dws-log-rotate.cron.log /tmp/dws-session-cleanup.cron.log
sed -n '1,120p' /tmp/dws-cleanup.last-success
```

Check the live monitor and queue first:

```bash
tail -n 40 /var/log/dws/monitor.log
sed -n '1,120p' ~/projects/dev-workspace/.state/task-queue.json
journalctl --user -u dws-task-monitor.service -n 50 --no-pager
```

If you need to inspect the legacy `/tmp` artifacts that some repo tools still
read:

```bash
sed -n '1,120p' /tmp/monitor-status.json 2>/dev/null || true
tail -n 40 /tmp/planner-log.txt /tmp/orchestrator-monitor.log
```

## Practical Takeaway

The current operational surfaces are:

1. `/var/log/dws/monitor.log` for the live task-monitor cycle log.
2. `~/projects/dev-workspace/.state/task-queue.json` for the live queue state.
3. `/tmp` for health, cron, planner, alert, and legacy status artifacts.
4. `journald` for user-service stdout/stderr when the script does not manage its
   own file log.

Treat the current state as a partial migration, not a completed centralization.
