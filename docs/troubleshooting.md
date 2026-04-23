# Troubleshooting

Quick fixes for the failures that show up most often in `dev-workspace`.

| Issue | Fix |
| --- | --- |
| SSH connection drops | Your shell is running inside `tmux`, so the session survives. SSH back in and run `tmux attach` to resume. |
| Codex compaction error | When the session falls back to `Session ended. [r]estart / [q]uit:`, press `r` to restart in the same `tmux` session. |
| Foundry API key missing | Run `source ~/.config/wrkflo/foundry.env`. If the launcher still reports `key=missing`, check the `key_status` line in the launcher and confirm the env file exists. |
| Tailscale not connected | Rejoin the tailnet with `sudo tailscale up`, then retry the SSH or bridge command. |
| `tmux` session name conflicts | Remove the stale session with `scripts/dws-sessions.sh kill <name>`, then relaunch. |
| Mac bridges not responding | On the Mac, run `launchctl list | grep wrkflo`. If the agents are missing or exited, restart the bridge LaunchAgents and try again. |
| Git push rejected | The remote moved first. Run `git pull --rebase`, resolve conflicts if needed, then `git push` again. |
| VM disk full | Free space with `dws-cleanup.sh`, then rerun the failed command. |

See also [`docs/launcher.md`](./launcher.md), [`docs/foundry.md`](./foundry.md), [`docs/tailscale.md`](./tailscale.md), and [`docs/mac-bridge.md`](./mac-bridge.md).
