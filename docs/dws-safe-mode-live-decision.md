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

- `dws-sessions-init.service` is enabled and `active (exited)`
- `dws-safe-mode.service` is installed at
  `~/.config/systemd/user/dws-safe-mode.service`
- the installed unit matches
  `config/systemd-user/dws-safe-mode.service`
- `systemctl --user is-enabled dws-safe-mode.service` returns `disabled`
- `systemctl --user status dws-safe-mode.service` shows `inactive (dead)`
- `~/projects/dev-workspace/bin/dws-systemd-user-setup.sh check` passes

## Broader Drift Notes

The safe-mode decision remains correct, but a broader runtime spot check showed
one separate drift item outside this lane:

- the retired `dws-task-monitor.service` is absent
- `~/bin/dws-sessions-init.sh` matches `scripts/dws-sessions-init.sh`
- `~/bin/dws-boot-verify.sh` does **not** match
  `bin/dws-boot-verify.sh`
- `curl` checks for `/healthz`, `/v1/projects`, and `/v1/workspace/projects`
  all return `200`

That older installed `dws-boot-verify.sh` copy does not change the safe-mode
decision: the repo-owned safe-mode unit is installed and should stay disabled on
this VM. It does mean the earlier claim that the broader DWS runtime drift was
fully reconciled is no longer accurate.

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
systemctl --user status dws-task-monitor.service --no-pager
curl -sS -o /tmp/dws-healthz.json -w "%{http_code}\n" http://127.0.0.1:8100/healthz
curl -sS -o /tmp/dws-projects.json -w "%{http_code}\n" http://127.0.0.1:8100/v1/projects
curl -sS -o /tmp/dws-workspace-projects.json -w "%{http_code}\n" \
  http://127.0.0.1:8100/v1/workspace/projects
```
