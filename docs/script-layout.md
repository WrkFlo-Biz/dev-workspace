# Script Layout

## Convention

- `scripts/` is the canonical source for repo-owned shell entrypoints and helper
  programs.
- Most files in `bin/` are thin repo-local wrappers that `exec` into
  `scripts/`.
- `bin/dws-boot-verify.sh` and `bin/dws-systemd-user-setup.sh` are standalone
  repo-owned entrypoints, not wrappers.
- `~/bin/` on the VM is the live runtime install path for copied scripts,
  direct symlinks into `scripts/`, and host-local copies of some repo-tracked
  scripts.
- `scripts/task-monitor.sh` remains in the repo as a host-local runtime source
  snapshot and compatibility reference. It is not wired to a current
  repo-managed user unit.

## Wrapper Pattern

Example wrapper: `bin/dws-status.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASH_SOURCE[0]%/*}"
[ "$BASE_DIR" != "${BASH_SOURCE[0]}" ] || BASE_DIR='.'
BASE_DIR=$(CDPATH='' cd -- "$BASE_DIR" && pwd)
exec "${BASE_DIR}/../scripts/dws-status.sh" "$@"
```

All repo wrappers should use the `BASH_SOURCE` + `BASE_DIR` contract above so
they work from any current working directory. `tests/test_bin_wrappers.sh`
verifies that contract for every non-standalone `bin/*.sh` wrapper.

Operational rule:

- edit the canonical file under `scripts/`
- keep `bin/` wrappers minimal
- if you need a VM-local `~/bin` command, copy the script there or symlink
  `~/bin/<name>` directly to `~/projects/dev-workspace/scripts/<name>`

Do not symlink the repo `bin/` wrappers into `~/bin`; those wrappers resolve
`../scripts` relative to their own path and can break when invoked through a
different directory.

## Selected Repo Entry Points

This section is intentionally curated, not exhaustive. For the full tracked
surface, use:

```bash
rg --files scripts bin | sort
```

High-traffic canonical scripts:

- `dws-backup.sh`
- `dws-cleanup.sh`
- `dws-connect-test.sh`
- `dws-cron-setup.sh`
- `dws-doctor.sh`
- `dws-health-check.sh`
- `dws-health.sh`
- `dws-launcher.sh`
- `dws-notify.sh`
- `dws-queue-inspector.sh`
- `dws-reboot-drill.sh`
- `dws-service-map.sh`
- `dws-summary.sh`
- `dws-worker-exec.sh`
- `task-monitor.sh` (host-local legacy/runtime snapshot, not a repo-managed
  service entrypoint)
- `vm-setup.sh`

High-traffic repo `bin/` wrappers:

- `dws-alerting.sh`
- `dws-backup.sh`
- `dws-cleanup.sh`
- `dws-connect-test.sh`
- `dws-cron-setup.sh`
- `dws-doctor.sh`
- `dws-firewall.sh`
- `dws-health-full.sh`
- `dws-log-viewer.sh`
- `dws-motd.sh`
- `dws-queue-inspector.sh`
- `dws-reboot-drill.sh`
- `dws-rotate-logs.sh`
- `dws-service-map.sh`
- `dws-sessions-init.sh`
- `dws-sessions.sh`
- `dws-status.sh`
- `dws-summary.sh`
- `dws-sync-mac.sh`
- `dws-tailscale-diag.sh`
- `dws-termius-setup.sh`
- `dws-worker-utilization.sh`
- `vm-setup.sh`

Standalone repo `bin/` entrypoints:

- `dws-boot-verify.sh`
- `dws-systemd-user-setup.sh`

## Quick Audit Commands

```bash
rg --files scripts bin | sort
bash tests/test_bin_wrappers.sh
sed -n '1,40p' bin/dws-status.sh
sed -n '1,80p' bin/dws-boot-verify.sh
```
