# Wrk-Flo orchestrator workspace

`wrkflo-orchestrator` is a sibling project under `~/projects`, not part of the
`dev-workspace` repo. Keep the boundary clean:

- `dev-workspace` owns VM access, launcher config, Mac relays, Tailscale, and
  operator bootstrap.
- `wrkflo-orchestrator` owns agent coordination, workflow state, contracts,
  retries, compensation, and replay/debug tools.

## Current scaffold

The initial project lives at:

```bash
~/projects/wrkflo-orchestrator
```

It is a dependency-light Python package with:

- immutable append-only `StateSnapshot` objects
- handoff `Contract` validation
- a central `Orchestrator`
- narrow `Agent` / `FunctionAgent` worker boundaries
- circuit-breaker protection for agent/tool calls
- reverse-order compensation hooks
- a small CLI demo and unit tests

## Local verification

```bash
cd ~/projects/wrkflo-orchestrator
PYTHONPATH=src python3 -m unittest discover -s tests
PYTHONPATH=src python3 -m wrkflo_orchestrator.cli demo
```

## Launcher entry

The dev-workspace launcher includes `wrkflo-orchestrator` as a first-class
workspace target. It should use the `foundry-5_4` profile by default because
orchestrator work is architecture-heavy and cross-cutting.

## Next build steps

1. Move the scaffold to the live VM under `/home/moses/projects` if it only
   exists on the Mac.
2. Put the project under GitHub as `Wrk-Flo/wrkflo-orchestrator`.
3. Replace demo agents with real worker adapters for GitHub, Azure, Mac GUI,
   Chrome CDP, repo edit/test jobs, OpenClaw, and voice-agent ops.
4. Persist workflow runs to SQLite or Postgres instead of in-memory storage.
5. Add a CLI inspector for run history, circuit state, failed steps, and
   compensation results.
