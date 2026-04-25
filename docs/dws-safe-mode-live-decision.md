# dws-safe-mode Live Decision — 2026-04-25 UTC

## Decision

`dws-safe-mode.service` should be installed on this VM, but it should remain
disabled by default.

## Why It Must Stay Disabled

The repo-owned unit is a maintenance profile, not a normal boot target:

- `ExecStart` runs `~/projects/dev-workspace/bin/dws-safe-mode.sh --service-start`
- `Before=` and `Conflicts=` include both `dws-sessions-init.service` and
  `wrkflo-orchestrator-api.service`
- `WantedBy=default.target` means enabling it would activate safe mode during
  normal user-manager startup

In practice, enabling the unit would put the VM into maintenance mode on boot:
the safe-mode wrapper creates the safe-mode flag and stops the normal
session/bootstrap and orchestrator control-plane units. That is the opposite of
the intended steady-state runtime for this VM.

## Live Result

- `dws-safe-mode.service` is installed at
  `~/.config/systemd/user/dws-safe-mode.service`
- the installed unit matches
  `config/systemd-user/dws-safe-mode.service`
- `systemctl --user is-enabled dws-safe-mode.service` returns `disabled`
- `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check` passes

## Drift Re-Verification

The DWS service/runtime drift tied to this mission is currently reconciled:

- `dws-sessions-init.service` is installed, enabled, and `active (exited)`
- `dws-safe-mode.service` is installed and `disabled`
- the installed user-unit files match the repo copies
- the retired `dws-task-monitor.service` is absent
- `~/bin/dws-sessions-init.sh` matches `scripts/dws-sessions-init.sh`
- `~/bin/dws-boot-verify.sh` matches `bin/dws-boot-verify.sh`
- `curl` checks for `/healthz`, `/v1/projects`, and `/v1/workspace/projects`
  all return `200`

## Verification Commands

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check
systemctl --user is-enabled dws-sessions-init.service dws-safe-mode.service
systemctl --user status dws-sessions-init.service dws-safe-mode.service --no-pager
cmp -s ~/projects/dev-workspace/config/systemd-user/dws-safe-mode.service \
  ~/.config/systemd/user/dws-safe-mode.service
cmp -s ~/projects/dev-workspace/scripts/dws-sessions-init.sh \
  ~/bin/dws-sessions-init.sh
cmp -s ~/projects/dev-workspace/bin/dws-boot-verify.sh \
  ~/bin/dws-boot-verify.sh
curl -sS -o /tmp/dws-healthz.json -w "%{http_code}\n" http://127.0.0.1:8100/healthz
curl -sS -o /tmp/dws-projects.json -w "%{http_code}\n" http://127.0.0.1:8100/v1/projects
curl -sS -o /tmp/dws-workspace-projects.json -w "%{http_code}\n" \
  http://127.0.0.1:8100/v1/workspace/projects
```
