# QA Review

Reviewed the current `dev-workspace` working tree on 2026-04-24 UTC.

Treat this file as a dated review snapshot. Some findings below are historical
and may already be resolved in newer commits. For current runtime surfaces and
live-path guidance, prefer `docs/logging.md` and `docs/runtime-boot-truth.md`.

## Scope

- `README.md`
- tracked markdown under `docs/`
- `bin/*.sh`, `scripts/*`, `config/systemd-user/*`
- repo shell test suite: `bash tests/test_*.sh`

## What Passed

- The targeted verification files for the on-demand-model cleanup pass:
  `bash tests/test_bin_wrappers.sh` and `bash tests/test_dws_boot_verify.sh`.
- All current `bin/*.sh` entrypoints are syntactically valid under `bash -n`.
- Wrapper audit: the repo `bin/` entrypoints that delegate into `scripts/` all resolve to existing targets.
- Repo-relative doc references to tracked files are mostly clean; the defects below came from doc-to-code drift, not from a broad set of broken local links.

## Findings

### High: docs still describe a retired repo-managed `dws-task-monitor.service`

Evidence:

- `bin/dws-systemd-user-setup.sh` now installs only `dws-sessions-init.service`
  and `dws-safe-mode.service`, and explicitly retires `dws-task-monitor.service`.
- `config/systemd-user/` now contains only the repo-owned `dws-sessions-init`
  and `dws-safe-mode` units.
- Older operator docs still referred to `dws-task-monitor.service` as if the
  repo installed and enabled it.

Impact:

- Operators can follow the wrong setup or reboot-recovery path and mistake
  host-local runtime drift for a repo regression.

### Medium: legacy queue-path defaults still exist in some repo tools

Evidence:

- Docs call `~/projects/dev-workspace/.state/task-queue.json` authoritative in `docs/architecture.md:233-260`, `docs/runbook.md:10`, `docs/runbook.md:114-127`, and `docs/troubleshooting.md:21-24`, `docs/troubleshooting.md:202-208`.
- `scripts/dws-launcher.sh:424-443` and `scripts/dws-status.sh:270-289` now probe the repo `.state` queue before falling back to `/tmp/task-queue.json`.
- `scripts/dws-motd.sh:1-6` still defaults directly to `/tmp/task-queue.json` unless `DWS_TASK_QUEUE_PATH` is set.

Impact:

- Launcher and status are closer to the runbook now, but MOTD output can still point at a stale queue file on hosts that use the `.state` queue.

### Medium: monitor-log docs point at `/var/log/dws/monitor.log`, but repo readers still default to `/tmp/monitor-log.txt`

Evidence:

- Docs treat `/var/log/dws/monitor.log` as the live monitor log in multiple
  runbook and troubleshooting paths.
- Repo readers still default to `/tmp/monitor-log.txt` in `scripts/dws-doctor.sh:28-30` and `scripts/dws-sessions.sh:6-8`.
- Any actual monitor writer is now external to the repo-owned unit set via a
  host-local `~/bin/task-monitor.sh`, so the repo itself cannot prove
  `/var/log/dws/monitor.log` without a host-local script check.

Impact:

- Triage instructions and repo tooling can disagree about which monitor log is authoritative.

### Medium: phone-control docs assume install paths and services that this repo does not provision

Evidence:

- `docs/phone-control.md:29-34` says the VM side is `~/bin/dws-phone-server.py` plus `~/bin/push-phone`.
- `docs/phone-control.md:46-64` and `docs/phone-control.md:101-118` instruct the operator to run `push-phone`, but there is no tracked `push-phone` script in this repo.
- The repo does contain `scripts/dws-phone-server.py:1-39`, but there is no tracked phone-server wrapper under repo `bin/` and no tracked `dws-phone-server.service` unit.
- The repo installers only deploy launcher/health/notifier-related files: `scripts/vm-setup.sh:811-815` and `scripts/dws-update.sh:6-10`.
- Reboot docs also assume the missing service exists, for example `docs/reboot-recovery-test.md:18`, `docs/reboot-recovery-test.md:121`, and `docs/reboot-recovery-test.md:144-151`.

Impact:

- A reader cannot reproduce the documented phone-control setup from this repo alone; key entrypoints and the service unit are undocumented external dependencies.

## Wrapper Audit Summary

- Wrapper targets verified: `bin/dws-backup.sh`, `dws-cleanup.sh`, `dws-connect-test.sh`, `dws-cron-setup.sh`, `dws-doctor.sh`, `dws-firewall.sh`, `dws-health-full.sh`, `dws-log-viewer.sh`, `dws-motd.sh`, `dws-rotate-logs.sh`, `dws-sessions-init.sh`, `dws-sessions.sh`, `dws-status.sh`, `dws-sync-mac.sh`, `dws-tailscale-diag.sh`, `dws-termius-setup.sh`, `vm-setup.sh`.
- Standalone repo-owned `bin/` programs: `bin/dws-boot-verify.sh`, `bin/dws-systemd-user-setup.sh`.

## Recommendation Order

1. Finish aligning the remaining legacy queue and monitor-log readers with the documented runtime surfaces.
2. Either add repo-managed provisioning for the phone-control entrypoints or rewrite the phone docs to state clearly that they are host-local, operator-managed dependencies.
