# QA Review

Reviewed the current `feat/dws-boot-verify` working tree on 2026-04-23 UTC.

## Scope

- `README.md`
- tracked markdown under `docs/`
- `bin/*.sh`, `scripts/*`, `config/systemd-user/*`
- repo shell test suite: `bash tests/test_*.sh`

## What Passed

- `bash tests/test_*.sh` passes on the current tree.
- All current `bin/*.sh` entrypoints are syntactically valid under `bash -n`.
- Wrapper audit: the repo `bin/` entrypoints that delegate into `scripts/` all resolve to existing targets.
- Repo-relative doc references to tracked files are mostly clean; the defects below came from doc-to-code drift, not from a broad set of broken local links.

## Findings

### High: `dws-boot-verify.sh` checks the wrong task-monitor unit name

Evidence:

- `bin/dws-boot-verify.sh:8` defaults `TASK_MONITOR_UNIT` to `task-monitor.service`.
- `bin/dws-boot-verify.sh:44-50` documents `task-monitor.service` as the required service.
- `config/systemd-user/dws-task-monitor.service:1-17` defines the repo-managed unit as `dws-task-monitor.service`.
- The operator docs also use `dws-task-monitor.service`, for example `docs/runbook.md:14`, `docs/runbook.md:39-47`, and `docs/reboot-recovery-test.md:17`, `docs/reboot-recovery-test.md:135-142`.

Impact:

- A correctly installed system can fail the repo's own boot smoke test unless `DWS_BOOT_VERIFY_TASK_MONITOR_UNIT` is overridden.

### High: queue-path docs point at `.state/task-queue.json`, but repo consumers still read `/tmp/task-queue.json`

Evidence:

- Docs call `~/projects/dev-workspace/.state/task-queue.json` authoritative in `docs/architecture.md:233-260`, `docs/runbook.md:10`, `docs/runbook.md:114-127`, and `docs/troubleshooting.md:21-24`, `docs/troubleshooting.md:202-208`.
- Current repo consumers still default to `/tmp/task-queue.json` in `scripts/dws-launcher.sh:34-38`, `scripts/dws-status.sh:6-9`, and `scripts/dws-motd.sh:4-6`.

Impact:

- Operators following the runbook or troubleshooting guide can inspect or edit a different queue file than the one the launcher, status view, and MOTD are actually using.

### Medium: monitor-log docs point at `/var/log/dws/monitor.log`, but repo readers still default to `/tmp/monitor-log.txt`

Evidence:

- Docs treat `/var/log/dws/monitor.log` as the live monitor log in `docs/architecture.md:233-260`, `docs/runbook.md:16`, `docs/runbook.md:41-47`, `docs/runbook.md:91-107`, and `docs/troubleshooting.md:13-18`, `docs/troubleshooting.md:202-217`.
- Repo readers still default to `/tmp/monitor-log.txt` in `scripts/dws-doctor.sh:28-30` and `scripts/dws-sessions.sh:6-8`.
- The actual monitor writer is still external to this repo via `%h/bin/task-monitor.sh` in `config/systemd-user/dws-task-monitor.service:5-14`, so the repo itself cannot prove `/var/log/dws/monitor.log` without a host-local script check.

Impact:

- Triage instructions and repo tooling can disagree about which monitor log is authoritative.

### Medium: `docs/script-layout.md` is stale and no longer describes the current repo

Evidence:

- `docs/script-layout.md:5-16` says `bin/` contains thin wrappers and that every file follows one wrapper pattern.
- That is no longer true: `bin/dws-boot-verify.sh:1-20` and `bin/dws-systemd-user-setup.sh:1-20` are standalone repo-owned entrypoints, not thin wrappers.
- The "Current inventory" in `docs/script-layout.md:27-53` omits many current repo scripts, including `apply-codex-profiles.sh`, `dws-env.sh`, `dws-log-viewer.sh`, `dws-log.sh`, `dws-notify.sh`, `dws-phone-server.py`, `dws-quick.sh`, `dws-rotate-logs.sh`, `dws-update.sh`, `sync-mac-to-vm.sh`, and `sync-vm-to-mac.sh`.

Impact:

- New contributors get the wrong mental model for how `bin/` works and miss a large part of the current script surface.

### Medium: phone-control docs assume install paths and services that this repo does not provision

Evidence:

- `docs/phone-control.md:29-34` says the VM side is `~/bin/dws-phone-server.py` plus `~/bin/push-phone`.
- `docs/phone-control.md:46-64` and `docs/phone-control.md:101-118` instruct the operator to run `push-phone`, but there is no tracked `push-phone` script in this repo.
- The repo does contain `scripts/dws-phone-server.py:1-39`, but there is no tracked `bin/` wrapper for it and no tracked `dws-phone-server.service` unit.
- The repo installers only deploy launcher/health/notifier-related files: `scripts/vm-setup.sh:811-815` and `scripts/dws-update.sh:6-10`.
- Reboot docs also assume the missing service exists, for example `docs/reboot-recovery-test.md:18`, `docs/reboot-recovery-test.md:121`, and `docs/reboot-recovery-test.md:144-151`.

Impact:

- A reader cannot reproduce the documented phone-control setup from this repo alone; key entrypoints and the service unit are undocumented external dependencies.

## Wrapper Audit Summary

- Wrapper targets verified: `bin/dws-backup.sh`, `dws-cleanup.sh`, `dws-connect-test.sh`, `dws-cron-setup.sh`, `dws-doctor.sh`, `dws-firewall.sh`, `dws-health-full.sh`, `dws-log-viewer.sh`, `dws-motd.sh`, `dws-rotate-logs.sh`, `dws-sessions-init.sh`, `dws-sessions.sh`, `dws-status.sh`, `dws-sync-mac.sh`, `dws-tailscale-diag.sh`, `dws-termius-setup.sh`, `vm-setup.sh`.
- Standalone repo-owned `bin/` programs: `bin/dws-boot-verify.sh`, `bin/dws-systemd-user-setup.sh`.

## Recommendation Order

1. Fix `bin/dws-boot-verify.sh` to default to `dws-task-monitor.service`.
2. Choose one authoritative queue path and one authoritative monitor-log path, then align the docs and the repo readers to that choice.
3. Update `docs/script-layout.md` to reflect the current `bin/` model and current inventory.
4. Either add repo-managed provisioning for the phone-control entrypoints or rewrite the phone docs to state clearly that they are host-local, operator-managed dependencies.
