# Dev Workspace Handoff — 2026-04-24 UTC

This handoff reflects the checked-in `dev-workspace` repo and the current
operator model. It intentionally avoids sibling-repo implementation details
that this repo does not provision.

## Current Repo Truth

- Shell verification entrypoint: `bash tests/run_all.sh`
- `bin/` is the repo-local operator surface. Most `bin/*.sh` files are thin
  wrappers that `exec` into `scripts/`.
- Standalone repo `bin/` programs: `bin/dws-boot-verify.sh`,
  `bin/dws-systemd-user-setup.sh`
- `scripts/dws-sessions-init.sh` implements an on-demand `tmux` model. It does
  not create a fixed worker pool at boot.
- Repo-managed user services: `dws-sessions-init.service`,
  `dws-task-monitor.service`
- The live monitor service still executes the host-local
  `~/bin/task-monitor.sh`; the repo copy under `scripts/` is a source snapshot,
  not the installed runtime entrypoint.
- Authoritative runtime surfaces are
  `~/projects/dev-workspace/.state/task-queue.json` and
  `/var/log/dws/monitor.log`.

## Session And Service Model

- SSH login normally lands in `~/bin/dws-launcher.sh`, then into `tmux`, then
  into Codex or Claude for the selected repo/profile.
- `tmux` session names are runtime state, not a repo-guaranteed boot contract.
  Expect ad hoc names like `dws-5-4`, `gs-claude`, or `orch-codex`; older
  `dws-a` and `worker-*` snapshots are historical only.
- `dws-sessions-init.service` performs lightweight boot prep for the on-demand
  model.
- `dws-task-monitor.service` runs independently of interactive shells and
  manages the live queue and host-defined worker/orchestrator state.

## Operator Surface

- `~/projects/dev-workspace/bin/dws-status.sh`
- `~/projects/dev-workspace/bin/dws-sessions.sh list`
- `~/projects/dev-workspace/bin/dws-summary.sh`
- `~/projects/dev-workspace/bin/dws-service-map.sh`
- `~/projects/dev-workspace/bin/dws-boot-verify.sh`
- `systemctl --user status dws-sessions-init.service dws-task-monitor.service --no-pager`
- `tail -n 40 /var/log/dws/monitor.log`

## Drift Rules

- If repo docs and live behavior disagree, trust active user-service state, the
  installed `~/bin` entrypoints, `/var/log/dws/monitor.log`, and the repo
  `.state` queue first.
- `~/bin/` can drift from checked-in `bin/` and `scripts/`; redeploy before
  assuming the host matches the repo.
- Host-local services such as `dws-phone-server.service` or
  `wrkflo-orchestrator-api.service` can exist on the VM, but they are not
  installed by this repo.

## Resume Checklist

1. `git -C ~/projects/dev-workspace status --short`
2. `bash ~/projects/dev-workspace/tests/run_all.sh`
3. `systemctl --user status dws-sessions-init.service dws-task-monitor.service --no-pager`
4. `~/projects/dev-workspace/bin/dws-boot-verify.sh`
5. `~/projects/dev-workspace/bin/dws-sessions.sh list`

Primary reference docs:

- `docs/architecture.md`
- `docs/runtime-boot-truth.md`
- `docs/runbook.md`
