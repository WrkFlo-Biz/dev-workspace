# Live Drift Findings — 2026-04-25 UTC

## Summary

The live VM no longer matches the stale drift snapshot that kicked off this
mission. By the time Phase 0 was completed, the runtime issues called out in
the earlier handoff had already been repaired.

## Findings

- The earlier control-plane failure (`path escapes workspace: dev-workspace`)
  is not present in the live API anymore; both project-listing endpoints now
  return `200`.
- `dws-sessions-init.service` is no longer failed. It now runs the on-demand
  bootstrap path and exits successfully.
- `dws-safe-mode.service` is installed live and remains disabled by default,
  which matches the repo-owned intent.
- The retired `dws-task-monitor.service` is absent (`not-found`), which is the
  intended end state on this VM.
- `wrkflo-orchestrator-api.service` is enabled at boot and active. On this VM,
  the host-installed orchestrator service is intentionally present and aligned
  with the current boot policy.

## Repairs Confirmed Earlier In The Same Mission

A delegated infra pass reported and verified these repairs before the final
Phase 0 re-check:

- workspace-path normalization in `wrkflo-orchestrator`
- removal of the stale `dws-task-monitor.service`
- reinstall of repo-managed user units
- boot-policy alignment for `wrkflo-orchestrator-api.service`

This document therefore records the post-repair runtime truth, not the earlier
pre-fix failure state.

## Follow-Up

- Keep runtime docs aligned to the live unit graph: repo-owned units are
  `dws-sessions-init.service` and `dws-safe-mode.service`.
- Treat `wrkflo-orchestrator-api.service` as an intentionally installed
  host-local sibling service on this VM.
- If `/v1/projects` regresses again, inspect `wrkflo-orchestrator` workspace
  root resolution before changing `dev-workspace`.

## Verification Commands

```bash
systemctl --user status wrkflo-orchestrator-api.service --no-pager
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user is-enabled dws-safe-mode.service
systemctl --user is-enabled dws-task-monitor.service
journalctl --user -u dws-sessions-init.service --no-pager -n 40
curl -sS -o /tmp/projects.json -w "%{http_code}\n" \
  http://127.0.0.1:8100/v1/projects
curl -sS -o /tmp/workspace-projects.json -w "%{http_code}\n" \
  http://127.0.0.1:8100/v1/workspace/projects
```
