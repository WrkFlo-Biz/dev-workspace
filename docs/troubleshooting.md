# Troubleshooting

Common failures in `dev-workspace` and the shortest path to recovery.

## SSH Drops

Symptoms:
- Termius or Terminal disconnects mid-session
- Phone sleeps and the SSH session dies

Fix:
1. Reconnect to `moses@dev-workspace-vm` over Tailscale.
2. In the launcher, press `r` to reconnect to the last `tmux` session.
3. If needed, run `bash scripts/dws-sessions.sh list` and reconnect by name.

Checks:
- Prefer `dev-workspace-vm` over the public IP; use `20.230.203.79` only as fallback.
- If reconnect fails entirely, verify Tailscale on both devices and rerun `bash scripts/dws-health.sh`.

## Foundry Key Missing

Symptoms:
- Launcher shows `key=missing`
- Codex requests fail because `AZURE_OPENAI_API_KEY` is not loaded

Fix:
1. Check the env file: `ls -l ~/.config/wrkflo/foundry.env`
2. Load it into the current shell: `. ~/.config/wrkflo/foundry.env`
3. Re-run `bash scripts/dws-health.sh` and confirm `foundry key loaded`

If the file is missing:
1. Ensure `az login` works on the VM
2. Re-run `bash scripts/vm-bootstrap.sh` or fetch the key again through Azure

## tmux Session Recovery

Symptoms:
- SSH reconnects but your Codex or Claude session is gone from the terminal
- The launcher appears, but your agent is still running somewhere else

Fix:
1. Run `bash scripts/dws-sessions.sh list`
2. Reattach with `bash scripts/dws-sessions.sh reconnect <session>`
3. From inside `tmux`, use `Ctrl-a d` to detach cleanly instead of closing the shell

If a stale session blocks relaunch:
1. Kill it with `bash scripts/dws-sessions.sh kill <session>`
2. Start a fresh one from the launcher or `bash scripts/dws-quick.sh <project> <model>`

## Codex Compaction Errors

Symptoms:
- Codex exits unexpectedly after a long session
- You see a compaction/context failure and drop back to `Session ended. [r]estart / [q]uit:`

Fix:
1. Press `r` to restart inside the same `tmux` session
2. If the session is already gone, reconnect and relaunch from the launcher
3. Before restarting again, write a short handoff note in the repo so the next run starts with less context debt

If it keeps happening:
1. Start a new session with a cleaner prompt and smaller working set
2. Move long logs or giant pasted blobs out of the active conversation
3. Prefer `gpt-5.4` for harder recovery work if the smaller profile is struggling

## Useful Commands

```bash
bash scripts/dws-health.sh
bash scripts/dws-log.sh alerts
bash scripts/dws-sessions.sh list
bash scripts/dws-sessions.sh reconnect
bash scripts/dws-quick.sh gs codex
```

See also `docs/launcher.md`, `docs/termius.md`, `docs/foundry.md`, and `docs/tailscale.md`.
