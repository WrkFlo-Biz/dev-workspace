# Runtime And Boot Truth

Observed on `dev-workspace-vm` on 2026-04-23 UTC.

This file records what the runtime and boot behavior actually looks like before
service-management cleanup and reboot hardening.

## Active runtime truth

Observed `tmux` sessions:

```text
dws-a
dws-b
monitor
orchestrator
worker-c
worker-d
worker-e
worker-f
worker-g
worker-h
```

Interpretation:

- `monitor` is the active queue/worker supervision loop
- `orchestrator` is a dedicated `wrkflo-orchestrator` Codex session
- `dws-a`, `dws-b`, and `worker-c` through `worker-h` are active worker panes

## Task monitor truth

Current monitor entrypoint:

- `~/bin/task-monitor.sh`

Current runtime behavior:

- runs inside the `tmux` session named `monitor`
- loops every `30` seconds
- manages eight worker sessions
- writes to:
  - `/tmp/monitor-log.txt`
  - `/tmp/monitor-status.json`
  - `/tmp/task-queue.json`
- recreates worker sessions that are dead, crashed, compacted, or stuck
- recreates the `orchestrator` `tmux` session if it disappears

Important limitation:

- the monitor is **not** currently managed by systemd
- it depends on a live `tmux` session and manual/session-init startup

## Queue truth

The runtime queue is live and mutable:

- source of truth: `/tmp/task-queue.json`
- status snapshot: `/tmp/monitor-status.json`

Observed during verification:

- queue totals and worker assignments were changing live while workers completed
  and picked up follow-on tasks
- this means queue docs must treat current counts as ephemeral, not static

## Systemd user service truth

User lingering is enabled:

- `loginctl show-user "$USER" -p Linger` -> `Linger=yes`

Active user services observed:

- `dws-phone-server.service`
- `wrkflo-orchestrator-api.service`

Service definitions:

- `dws-phone-server.service`
  - runs `%h/bin/dws-phone-server.py`
  - restart policy: `always`
  - binds the phone callback server on `0.0.0.0:8081`
- `wrkflo-orchestrator-api.service`
  - runs the orchestrator API on `127.0.0.1:8100`
  - restart policy: `on-failure`

Important gap:

- there is **no** `task-monitor.service`
- there is **no** managed service today that ensures the worker `tmux` pool or
  monitor loop come back after reboot

## Cron truth

`cron` is active and a managed `dev-workspace` block is installed in the user
crontab.

Observed entries:

- health check every 15 minutes
- log rotate / cleanup pass at 02:30 UTC
- session cleanup pass at 04:00 UTC

Current cron logs still write into `/tmp`:

- `/tmp/dws-health-check.cron.log`
- `/tmp/dws-log-rotate.cron.log`
- `/tmp/dws-session-cleanup.cron.log`

## Boot truth

What already recovers on reboot:

- `tailscaled`
- `ssh.socket` / `ssh.service`
- `cron`
- user systemd services because `Linger=yes`
  - `dws-phone-server.service`
  - `wrkflo-orchestrator-api.service`

What does **not** yet have managed boot recovery:

- `monitor` `tmux` session
- worker `tmux` sessions
- `orchestrator` `tmux` session
- automatic invocation of `bin/dws-sessions-init.sh`

## Session-init truth

There is already a bootstrap script:

- [`bin/dws-sessions-init.sh`](/home/moses/projects/dev-workspace/bin/dws-sessions-init.sh)

It can:

- create `dws-a`, `dws-b`, `worker-c`..`worker-h`, `orchestrator`, and `monitor`
- set `tmux` metadata for worker sessions
- verify each session becomes healthy
- reuse healthy sessions on rerun
- force recreation with `--force`

There is also a focused test:

- [`tests/test_dws_sessions_init.sh`](/home/moses/projects/dev-workspace/tests/test_dws_sessions_init.sh)

Current gap:

- the script exists, but nothing managed runs it automatically at boot

## Reboot-recovery truth

A full reboot-recovery drill has **not** yet been verified.

That means these claims are still unproven end to end:

- monitor auto-recovery after reboot
- worker pool auto-recovery after reboot
- launcher/session-init interplay after reboot
- Mac reconnect and phone operator path after reboot

## Recommended service-management direction

Minimal-risk next step:

1. keep `tmux` as the operator-visible worker substrate
2. add a user systemd service that runs `bin/dws-sessions-init.sh`
3. add a user systemd service for `~/bin/task-monitor.sh`
4. make those depend on network and user linger, not interactive login

This preserves the current workflow while removing manual boot dependence.

## Verification commands

```bash
tmux list-sessions
tmux capture-pane -t monitor -p | tail -40
sed -n '1,220p' /tmp/monitor-status.json
sed -n '1,220p' /tmp/task-queue.json
systemctl --user list-units --type=service --state=running --no-pager
systemctl --user cat dws-phone-server.service
systemctl --user cat wrkflo-orchestrator-api.service
loginctl show-user "$USER" -p Linger -p RuntimePath -p State
crontab -l
sed -n '1,260p' bin/dws-sessions-init.sh
sed -n '1,240p' tests/test_dws_sessions_init.sh
```
