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
- Repo-managed user services: `dws-sessions-init.service` and
  `dws-safe-mode.service` (`dws-safe-mode.service` is installed but disabled by
  default).
- The legacy `dws-task-monitor.service` is not repo-managed anymore. If a host
  still runs `~/bin/task-monitor.sh`, treat it as host-local runtime drift, not
  checked-in repo truth.
- Repo-owned coordination state lives under `~/projects/dev-workspace/.state/`,
  especially `task-queue.json`, `orchestrator-context.md`, and
  `orchestrator-handoff.md`.
- Optional host-local runtime surfaces can still include
  `/var/log/dws/monitor.log` and `dws-task-monitor.service`, but this repo does
  not install or enable them.

## Session And Service Model

- SSH login normally lands in `~/bin/dws-launcher.sh`, then into `tmux`, then
  into Codex or Claude for the selected repo/profile.
- `tmux` session names are runtime state, not a repo-guaranteed boot contract.
  Expect ad hoc names like `dws-5-4`, `gs-claude`, or `orch-codex`; older
  `dws-a` and `worker-*` snapshots are historical only.
- `dws-sessions-init.service` performs lightweight boot prep for the on-demand
  model.
- `dws-safe-mode.service` is the repo-managed stopgap profile for pausing
  session/bootstrap behavior without removing the installed units.
- A host-local `dws-task-monitor.service` can still exist on some VMs and may
  manage the live queue there, but it is outside the repo-owned unit set.

## Operator Surface

- `~/projects/dev-workspace/bin/dws-status.sh`
- `~/projects/dev-workspace/bin/dws-sessions.sh list`
- `~/projects/dev-workspace/bin/dws-summary.sh`
- `~/projects/dev-workspace/bin/dws-service-map.sh`
- `~/projects/dev-workspace/bin/dws-boot-verify.sh`
- `~/projects/dev-workspace/bin/dws-safe-mode.sh status`
- `systemctl --user status dws-sessions-init.service dws-safe-mode.service --no-pager`
- Optional host-local checks when installed:
  `systemctl --user status dws-task-monitor.service --no-pager`,
  `tail -n 40 /var/log/dws/monitor.log`

## Drift Rules

- If repo docs and live behavior disagree, trust active user-service state, the
  installed `~/bin` entrypoints, the repo `.state` queue, and the actual
  `systemctl --user` unit graph first.
- `~/bin/` can drift from checked-in `bin/` and `scripts/`; redeploy before
  assuming the host matches the repo.
- Host-local services such as `dws-phone-server.service` or
  `wrkflo-orchestrator-api.service` can exist on the VM, but they are not
  installed by this repo. The same rule now applies to any remaining
  `dws-task-monitor.service`.

## Resume Checklist

1. `git -C ~/projects/dev-workspace status --short`
2. `bash ~/projects/dev-workspace/tests/run_all.sh`
3. `systemctl --user status dws-sessions-init.service dws-safe-mode.service --no-pager`
4. `~/projects/dev-workspace/bin/dws-boot-verify.sh`
5. `~/projects/dev-workspace/bin/dws-sessions.sh list`
6. Optional host-local runtime checks if installed:
   `systemctl --user status dws-task-monitor.service --no-pager`,
   `tail -n 40 /var/log/dws/monitor.log`

Primary reference docs:

- `docs/architecture.md`
- `docs/runtime-boot-truth.md`
- `docs/runbook.md`
