# Runbook

Operate the VM from `~/projects/dev-workspace`.

## Start

1. Run `bash scripts/dws-doctor.sh` to catch missing key, Tailscale, disk, or CLI issues.
2. SSH to `moses@dev-workspace-vm` or run `bash scripts/dws-launcher.sh` on the VM.
3. Pick a project and model in the launcher, or use `bash scripts/dws-quick.sh <project> <model>`.
4. Verify state with `bash scripts/dws-health.sh` and `bash scripts/dws-sessions.sh list`.

## Stop

1. Detach from `tmux` with `Ctrl-a d` if you want the session to keep running.
2. Kill one session with `bash scripts/dws-sessions.sh kill <name>`.
3. Kill all sessions with `bash scripts/dws-sessions.sh kill-all`.
4. Clean up old detached sessions and stale temp files with `bash scripts/dws-cleanup.sh`.

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
4. Re-run `bash scripts/dws-health.sh` and `bash scripts/dws-doctor.sh`.

## Upgrade

1. Review pending deploy changes with `bash scripts/dws-update.sh --dry-run`.
2. Apply them with `bash scripts/dws-update.sh --force`.
3. For a fresh or drifted VM, run `bash scripts/vm-setup.sh`.
4. Re-check with `bash scripts/dws-health.sh`, `bash scripts/dws-doctor.sh`, and `bash scripts/dws-sessions.sh list`.
