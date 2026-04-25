# Runtime And Boot Truth

Updated for the checked-in repo state on 2026-04-24 UTC.

This file records the live runtime and boot behavior currently in use on the
VM, not just the checked-in repo intent.

## Repo-owned session truth

The checked-in repo now describes an on-demand session model:

- `scripts/dws-sessions-init.sh` does not spawn a fixed Codex worker pool.
- Repo-managed user-unit templates are:
  - `dws-sessions-init.service`
  - `dws-safe-mode.service`
- `tmux` sessions present on the VM are operator/runtime state, not a
  repo-guaranteed boot contract.

Historical note:

- older live snapshots included `dws-a`, `dws-b`, `orchestrator`, and several
  `worker-*` sessions
- those snapshots are still useful for incident archaeology, but they are not
  the current repo truth

## Optional host-local monitor truth

Some hosts still carry a host-local monitor outside the checked-in repo-owned
unit set.

Typical live entrypoint on those hosts:

- `~/bin/task-monitor.sh`

Typical live service:

- `dws-task-monitor.service`

Current runtime behavior:

- runs as a systemd user service, not inside `tmux`
- loops every `30` seconds
- manages a small host-local worker set defined by the installed runtime
- writes cycle logs to `/var/log/dws/monitor.log`
- reads and updates `~/projects/dev-workspace/.state/task-queue.json`
- recreates worker sessions that are dead, crashed, compacted, or stuck
- recreates the `orchestrator` `tmux` session if it disappears

Important note:

- this behavior is host-local legacy/runtime context, not a repo-managed unit
  contract
- some repo tooling and older docs still reference `/tmp/monitor-log.txt`,
  `/tmp/monitor-status.json`, or `/tmp/task-queue.json`
- those are legacy assumptions, not the authoritative repo-owned state files

## Queue truth

The repo-owned coordination queue is:

- source of truth: `~/projects/dev-workspace/.state/task-queue.json`
- keep only active `pending` / `in_progress` work in the live queue
- keep historical dumps and monitor snapshots out of repo-owned `.state/`

Operational implication:

- if `dws-status.sh` or `dws-doctor.sh` disagree with the checked-in repo
  truth, trust `systemctl --user`, `bin/dws-service-map.sh`, and the repo
  `.state` files first
- if a host-local task monitor is installed, its journal and
  `/var/log/dws/monitor.log` are runtime context, not repo-owned state

## Systemd user service truth

User lingering is enabled:

- `loginctl show-user "$USER" -p Linger` -> `Linger=yes`

Repo-managed user services:

- `dws-sessions-init.service`
- `dws-safe-mode.service`

Additional host-local or sibling-repo services observed on this VM:

- `dws-phone-server.service`
- `wrkflo-orchestrator-api.service`

Service definitions:

- `dws-sessions-init.service`
  - runs `%h/bin/dws-sessions-init.sh`
  - oneshot bootstrap for the on-demand session model
  - remains `active (exited)` after success
- `dws-safe-mode.service`
  - runs `%h/projects/dev-workspace/bin/dws-safe-mode.sh`
  - is installed but disabled by default
  - conflicts with `dws-sessions-init.service` when intentionally enabled
- optional host-local `dws-task-monitor.service`
  - runs `%h/bin/task-monitor.sh`
  - can still exist on drifted hosts
  - is not installed by `bin/dws-systemd-user-setup.sh`

## Boot truth

What already recovers on reboot:

- `tailscaled`
- `ssh.socket` / `ssh.service`
- `cron`
- user systemd services because `Linger=yes`
  - `dws-sessions-init.service`
  - `dws-safe-mode.service` remains installed but disabled unless the operator
    explicitly enabled it
  - additional host-local or sibling-repo services can also recover if they are
    installed on the VM
  - on this VM that currently includes `dws-phone-server.service` and
    `wrkflo-orchestrator-api.service`
  - on other hosts this can also include `dws-task-monitor.service`

What still needs explicit proof:

- a filled reboot drill result has not yet been committed into the repo
- the repo contains the drill plan and results template, but not a completed run

## Repo / live drift truth

The VM-local `~/bin` entrypoints can drift from the checked-in repo copies.

Observed examples before this repo sync:

- installed `~/bin/dws-sessions-init.sh` and `~/bin/dws-boot-verify.sh` could
  lag behind the checked-in repo copies
- some older docs described a fixed 10-session boot pool even after the repo
  moved to on-demand sessions

Operational rule:

- treat active user-service state plus the installed `~/bin` entrypoints as the
  live runtime truth
- treat the repo `bin/`, `scripts/`, and `config/systemd-user/` files as the
  source used to redeploy or reconcile the host
- distinguish repo-managed units from optional host-local services before you
  assume a reboot or setup regression belongs to this repo

## Verification commands

```bash
tmux list-sessions
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-safe-mode.service --no-pager
~/projects/dev-workspace/bin/dws-service-map.sh
sed -n '1,220p' ~/projects/dev-workspace/.state/task-queue.json
systemctl --user list-units --type=service --state=running --no-pager
loginctl show-user "$USER" -p Linger -p RuntimePath -p State
crontab -l
~/projects/dev-workspace/bin/dws-boot-verify.sh
~/projects/dev-workspace/scripts/dws-launcher.sh status
```

Optional host-local monitor checks when installed:

```bash
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```
