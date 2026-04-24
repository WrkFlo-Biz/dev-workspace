# Runtime And Boot Truth

Updated for the checked-in repo state on 2026-04-24 UTC.

This file records the live runtime and boot behavior currently in use on the
VM, not just the checked-in repo intent.

## Session truth

The checked-in repo now describes an on-demand session model:

- `scripts/dws-sessions-init.sh` does not spawn a fixed Codex worker pool.
- `dws-task-monitor.service` remains a user service, not a dedicated `tmux`
  pane.
- `tmux` sessions present on the VM are operator/runtime state, not a
  repo-guaranteed boot contract.

Historical note:

- older live snapshots included `dws-a`, `dws-b`, `orchestrator`, and several
  `worker-*` sessions
- those snapshots are still useful for incident archaeology, but they are not
  the current repo truth

## Task monitor truth

Current live entrypoint:

- `~/bin/task-monitor.sh`

Current live service:

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

- some repo tooling and older docs still reference `/tmp/monitor-log.txt`,
  `/tmp/monitor-status.json`, or `/tmp/task-queue.json`
- those are legacy assumptions, not the authoritative live task-monitor outputs

## Queue truth

The live queue is:

- source of truth: `~/projects/dev-workspace/.state/task-queue.json`
- primary monitor log: `/var/log/dws/monitor.log`

Operational implication:

- if `dws-status.sh` or `dws-doctor.sh` disagree with the service state, trust
  `systemctl --user`, `/var/log/dws/monitor.log`, and the `.state` queue first

## Systemd user service truth

User lingering is enabled:

- `loginctl show-user "$USER" -p Linger` -> `Linger=yes`

Repo-managed user services observed:

- `dws-sessions-init.service`
- `dws-task-monitor.service`

Additional host-local or sibling-repo services observed on this VM:

- `dws-phone-server.service`
- `wrkflo-orchestrator-api.service`

Service definitions:

- `dws-sessions-init.service`
  - runs `%h/bin/dws-sessions-init.sh`
  - oneshot bootstrap for the on-demand session model
  - remains `active (exited)` after success
- `dws-task-monitor.service`
  - runs `%h/bin/task-monitor.sh`
  - starts after `dws-sessions-init.service`
  - restart policy: `on-failure`
  - keeps the monitor loop alive independently of interactive logins

## Boot truth

What already recovers on reboot:

- `tailscaled`
- `ssh.socket` / `ssh.service`
- `cron`
- user systemd services because `Linger=yes`
  - `dws-sessions-init.service`
  - `dws-task-monitor.service`
  - additional host-local or sibling-repo services can also recover if they
    are installed on the VM, for example:
  - `dws-phone-server.service`
  - `wrkflo-orchestrator-api.service`

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

## Verification commands

```bash
tmux list-sessions
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
sed -n '1,220p' ~/projects/dev-workspace/.state/task-queue.json
systemctl --user list-units --type=service --state=running --no-pager
loginctl show-user "$USER" -p Linger -p RuntimePath -p State
crontab -l
~/projects/dev-workspace/bin/dws-boot-verify.sh
~/projects/dev-workspace/scripts/dws-launcher.sh status
```
