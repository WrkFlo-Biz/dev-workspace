# Script Layout

## Convention

- `scripts/` is the canonical source for repo-owned shell entrypoints and helper
  programs.
- Most files in `bin/` are thin repo-local wrappers that `exec` into
  `scripts/`.
- `bin/dws-boot-verify.sh` and `bin/dws-systemd-user-setup.sh` are standalone
  repo-owned entrypoints, not wrappers.
- `~/bin/` on the VM is the live runtime install path for copied scripts,
  direct symlinks into `scripts/`, and host-local helpers such as
  `task-monitor.sh`.

## Wrapper Pattern

Example wrapper: `bin/dws-status.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "${BASH:-/usr/bin/bash}" "${BASE_DIR}/../scripts/dws-status.sh" "$@"
```

Operational rule:

- edit the canonical file under `scripts/`
- keep `bin/` wrappers minimal
- if you need a VM-local `~/bin` command, copy the script there or symlink
  `~/bin/<name>` directly to `~/projects/dev-workspace/scripts/<name>`

Do not symlink the repo `bin/` wrappers into `~/bin`; those wrappers resolve
`../scripts` relative to their own path and can break when invoked through a
different directory.

## Current Repo Inventory

Canonical `scripts/` programs currently tracked here:

- `apply-codex-profiles.sh`
- `control-mac-chrome.js`
- `control-mac-chrome.sh`
- `control-mac-gui.py`
- `dws-backup.sh`
- `dws-bashrc.sh`
- `dws-cleanup.sh`
- `dws-connect-test.sh`
- `dws-cron-setup.sh`
- `dws-doctor.sh`
- `dws-env.sh`
- `dws-firewall.sh`
- `dws-health-check.sh`
- `dws-health-full.sh`
- `dws-health.sh`
- `dws-launcher.sh`
- `dws-log-viewer.sh`
- `dws-log.sh`
- `dws-motd.sh`
- `dws-notify.sh`
- `dws-phone-server.py`
- `dws-profile.sh`
- `dws-quick.sh`
- `dws-rotate-logs.sh`
- `dws-session-meta.sh`
- `dws-sessions-init.sh`
- `dws-sessions.sh`
- `dws-status.sh`
- `dws-sync-all.sh`
- `dws-sync-mac.sh`
- `dws-tailscale-diag.sh`
- `dws-termius-setup.sh`
- `dws-tunnel.sh`
- `dws-update.sh`
- `sync-mac-to-vm.sh`
- `sync-vm-to-mac.sh`
- `vm-bootstrap.sh`
- `vm-setup.sh`

Repo `bin/` wrappers currently tracked here:

- `dws-backup.sh`
- `dws-cleanup.sh`
- `dws-connect-test.sh`
- `dws-cron-setup.sh`
- `dws-doctor.sh`
- `dws-firewall.sh`
- `dws-health-full.sh`
- `dws-log-viewer.sh`
- `dws-motd.sh`
- `dws-rotate-logs.sh`
- `dws-sessions-init.sh`
- `dws-sessions.sh`
- `dws-status.sh`
- `dws-sync-mac.sh`
- `dws-tailscale-diag.sh`
- `dws-termius-setup.sh`
- `vm-setup.sh`

Standalone repo `bin/` entrypoints:

- `dws-boot-verify.sh`
- `dws-systemd-user-setup.sh`

## Quick Audit Commands

```bash
rg --files scripts bin | sort
sed -n '1,40p' bin/dws-status.sh
sed -n '1,80p' bin/dws-boot-verify.sh
```
