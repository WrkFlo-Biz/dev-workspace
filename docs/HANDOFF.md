# Dev Workspace Handoff — 2026-04-24 05:05 UTC

## What Was Built

### Infrastructure (dev-workspace repo — 164+ commits)
- **53 scripts** in `bin/` and `scripts/` — ops, health, monitoring, security, sync
- **24 tests** — all passing on VM, CI green (last 5+ runs)
- **25 docs** — runbooks, architecture, security, incident response
- **Firewall** — UFW deny-by-default, Tailscale-only SSH (100.64.0.0/10), all dev ports restricted
- **SSH hardening** — pubkey-only, no root, max 3 tries, Tailscale-only
- **3 cron jobs** — health check (15min), log rotation (daily 2:30AM), cleanup (daily 4AM)
- **Reboot recovery** — all services auto-recover, tested with full reboot drill
- **Rate-aware dispatch** — global throttle + per-worker exponential backoff
- **Safe mode** — `dws-safe-mode.sh on/off/status` stops workers while keeping SSH/health
- **Incident tools** — `dws-pause-dispatch.sh`, `dws-incident-export.sh` (diagnostic tarball)
- **Structured worker runner** — `dws-worker-exec.sh` (JSON task protocol)
- **Orchestrator boot script** — `scripts/dws-orchestrator-boot.sh` (one-command startup)

### Services (systemd user)
- `dws-phone-server.service` — active, port 8081 (Tailscale-only)
- `wrkflo-orchestrator-api.service` — active, port 8100
- `dws-task-monitor.service` — DISABLED (deprecated, replaced by orchestrator)
- `dws-sessions-init.service` — FAILED (being rewritten for on-demand model)

### wrkflo-orchestrator repo
- `codex_subprocess.py` — short-lived codex subprocess worker (DONE, tested, pushed)
  - Spawns codex as subprocess per task, captures output, kills on timeout
  - JSONL audit logging, state-store integration
  - Branch: `codex-subprocess-worker-clean` at commit `09bfe6b`
- Worker registry updated, __init__.py exports added
- 123 tests passing (full suite), 7 targeted subprocess tests
- Dashboard API with task history endpoints

### global-sentinel repo
- Fixed 11 failing trade_approval tests (table schema migration)
- State DB expansion, approval hardening
- All tests passing

### Network (Tailscale mesh — 4 devices)
| Device | IP | Status |
|--------|-----|--------|
| dev-workspace-vm | 100.117.16.63 | Online |
| mosess-macbook-air-3 | 100.78.207.22 | Active |
| iphone-15-pro-max | 100.88.249.22 | Online |
| openclaw-gateway-vm | 100.126.194.98 | Online |

### Access Paths (all verified)
- Mac → VM: SSH key over Tailscale
- Phone → VM: SSH key via Termius over Tailscale
- Phone → Mac: Password auth via Termius over Tailscale
- VM → GitHub: gh CLI with workflow scope
- VM → Azure: az CLI, subscription active

### CLI Tools (all authenticated on VM)
az, gh, codex, tailscale, ufw, elevenlabs

## What Was Deprecated
- **10-session tmux worker pool** — replaced by on-demand codex subprocesses
- **dws-task-monitor.service** — disabled, bash monitor replaced by Python orchestrator
- **dws-sessions-init.service** — being rewritten for single-orchestrator model
- **task-queue.json** — 299 tasks (286 completed, 13 cancelled), queue is clean

## What Still Needs Work
1. **Wire codex_subprocess.py into orchestrator control plane** — module exists, needs integration with task dispatch
2. **Session-init rewrite** — remove worker pool loop, keep orchestrator-only startup
3. **CI workflow consolidation** — ci.yml and test.yml both exist, merge into one
4. **Disk at 53%** — up from 39%, needs cleanup pass
5. **Phone → Mac SSH key auth** — script exists (`dws-termius-mac-fix.sh`), not yet run
6. **SQLite state layer** — still using JSON files for task queue

## The Plan Going Forward
One orchestrator session on the VM. SSH in → run `dws-orchestrator-boot.sh` → it monitors and dispatches.
The orchestrator spawns short-lived codex subprocesses per task via `codex_subprocess.py`.
No persistent worker pool. No Mac-side terminals coordinating. One entry point.

## How to Resume
```bash
ssh moses@100.117.16.63
dws-orchestrator-boot.sh 2    # orchestrator + 2 workers
tmux attach -t orchestrator   # watch it work
```

## Git State (all repos clean, all pushed)
- dev-workspace: `9ed0d50` — fix: shellcheck warnings in scripts
- wrkflo-orchestrator: `8afad7c` — feat: add task history CLI, service endpoints
- global-sentinel: `a2d49c7` — feat: openclaw state DB expansion
- wrkflo-voice-agents-ops: `59c4dda` — docs: add CLAUDE.md project context
- openclaw-prod: `6a3d2bb` — docs: add CLAUDE.md project context
- global-sentinel-azure-quantum: `37b5ce2` — docs: add CLAUDE.md project context
