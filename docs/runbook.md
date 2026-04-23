# Runbook

Operate the VM from `~/projects/dev-workspace`.

## Standard Paths

- Repo checkout: `~/projects/dev-workspace`
- Launcher: `~/bin/dws-launcher.sh`
- Sessions: `~/projects/dev-workspace/scripts/dws-sessions.sh`
- Health dashboard: `~/projects/dev-workspace/scripts/dws-health.sh`
- Doctor: `~/projects/dev-workspace/bin/dws-doctor.sh`

## Start

1. Run `~/projects/dev-workspace/bin/dws-doctor.sh` to check disk, memory, Tailscale, tmux, and cron health before launching more work.
2. SSH to `moses@dev-workspace-vm`, or run `~/bin/dws-launcher.sh` directly on the VM.
3. Pick a project and Codex profile in the launcher, or use `bash scripts/dws-quick.sh <project> <model>`.
4. Verify state with `bash scripts/dws-health.sh` and `bash scripts/dws-sessions.sh list`.

## Reconnect

1. List sessions: `bash scripts/dws-sessions.sh list`
2. Reattach to the newest session: `bash scripts/dws-sessions.sh reconnect`
3. Reattach to a specific session: `bash scripts/dws-sessions.sh reconnect <session>`
4. If you are already inside `tmux`, switch clients instead of starting a nested shell

## Manage Sessions

Use these commands when the launcher is not enough:

```bash
bash scripts/dws-sessions.sh list
bash scripts/dws-sessions.sh reconnect <session>
bash scripts/dws-sessions.sh kill <session>
bash scripts/dws-sessions.sh cleanup
```

Guidelines:
- Detach with `Ctrl-a d` instead of closing the SSH window when you want the session to survive
- Kill only stale or dead sessions that block relaunch
- Use `cleanup` to remove sessions older than 24 hours when the list gets noisy

## Replace Dead Workers

Symptoms:
- The launcher returns instead of showing an active Codex process
- `tmux` still has a stale session but the worker inside it is dead
- SSH reconnects, but the expected job is no longer making progress

Procedure:
1. List sessions: `bash scripts/dws-sessions.sh list`
2. Reattach to confirm the worker is actually dead: `bash scripts/dws-sessions.sh reconnect <session>`
3. If the pane is idle or the tool crashed out, kill the stale session: `bash scripts/dws-sessions.sh kill <session>`
4. Launch a replacement through the normal launcher flow
5. Leave a short handoff note in the repo if the previous worker produced partial work

## Health Checks

Use the dashboard for operator visibility:

```bash
bash scripts/dws-health.sh
```

Use the doctor for pass/warn/fail diagnostics:

```bash
bin/dws-doctor.sh
```

The doctor checks:
- Root disk usage
- Memory pressure
- Tailscale availability and connection state
- Active `tmux` sessions
- Installed cron jobs and how many are tagged `dws`

When the doctor fails:
1. Read the failing line first; it is already scoped to one subsystem
2. Fix the specific issue
3. Re-run `bin/dws-doctor.sh` until the summary reports `0 fail`

## Backup

1. Preview the backup with `bash scripts/dws-backup.sh --dry-run`.
2. Run `bash scripts/dws-backup.sh`.
3. Confirm the manifest at `/tmp/dws-backup-manifest.txt`.
4. Confirm the dated backup dir at `~/backups/YYYY-MM-DD/`.

What gets backed up:
- Repo branch name and commit hash for every git repo in `~/projects/`
- `~/.tmux.conf`
- `~/.config/wrkflo/foundry.env`
- `~/.config/codex/profiles/`

## Restore

1. Verify `~/projects/` repos already exist locally.
2. Restore repo branch pointers with `bash scripts/dws-backup.sh --restore`.
3. Restore configs from the dated backup dir into `~/.tmux.conf`, `~/.config/wrkflo/foundry.env`, and `~/.config/codex/profiles/`.
4. Re-run `bash scripts/dws-health.sh` and `bin/dws-doctor.sh`.

## Upgrade

1. Review pending deploy changes with `bash scripts/dws-update.sh --dry-run`.
2. Apply them with `bash scripts/dws-update.sh --force`.
3. For a fresh or drifted VM, run `bash scripts/vm-setup.sh`.
4. Re-check with `bash scripts/dws-health.sh`, `bin/dws-doctor.sh`, and `bash scripts/dws-sessions.sh list`.

## Common Failure Recovery

If SSH drops:
1. Reconnect to `moses@dev-workspace-vm`
2. Reattach with `bash scripts/dws-sessions.sh reconnect`

If Codex exits unexpectedly:
1. Reattach to confirm the session state
2. Kill the stale session if the worker is dead
3. Launch a fresh Codex session from the launcher
4. Leave a brief handoff note if the dead worker had partial progress

If the doctor reports pressure or missing services:
1. Address the failing subsystem first
2. Re-run `bin/dws-doctor.sh`
3. Do not launch more workers until the failing check is clean
