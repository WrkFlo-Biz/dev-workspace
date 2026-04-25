# Live Runtime Re-Verification — 2026-04-25 UTC

## Scope

Phase 0 was rerun directly on `dev-workspace-vm` to verify the live API,
user-service graph, and deployed session-init entrypoint before continuing the
broader mission.

## Current Live Truth

- `wrkflo-orchestrator-api.service` is `enabled` and `active`.
- `curl http://127.0.0.1:8100/v1/projects` returns `200`.
- `curl http://127.0.0.1:8100/v1/workspace/projects` returns `200`.
- `dws-sessions-init.service` is `enabled` and `active (exited)`.
- Installed `~/.config/systemd/user/dws-sessions-init.service` matches
  `config/systemd-user/dws-sessions-init.service`.
- Installed `~/bin/dws-sessions-init.sh` matches
  `scripts/dws-sessions-init.sh`.
- `dws-safe-mode.service` is installed and `disabled`.
- `dws-task-monitor.service` is `not-found`.

## Notes

- The older report of a live `/v1/projects` failure and a failed
  `dws-sessions-init.service` was stale by the time this pass ran.
- The current VM matches the repo-owned on-demand `tmux` model: lightweight
  boot prep only, no repo-guaranteed fixed worker pool, and safe mode installed
  but disabled by default.

## Verification Commands

```bash
curl -sS -o /tmp/projects.json -w "%{http_code}\n" \
  http://127.0.0.1:8100/v1/projects
curl -sS -o /tmp/workspace-projects.json -w "%{http_code}\n" \
  http://127.0.0.1:8100/v1/workspace/projects

systemctl --user is-enabled wrkflo-orchestrator-api.service
systemctl --user is-active wrkflo-orchestrator-api.service
systemctl --user is-enabled dws-sessions-init.service
systemctl --user is-active dws-sessions-init.service
systemctl --user is-enabled dws-safe-mode.service
systemctl --user is-enabled dws-task-monitor.service

diff -u ~/projects/dev-workspace/config/systemd-user/dws-sessions-init.service \
  ~/.config/systemd/user/dws-sessions-init.service
diff -u ~/projects/dev-workspace/scripts/dws-sessions-init.sh \
  ~/bin/dws-sessions-init.sh
```
