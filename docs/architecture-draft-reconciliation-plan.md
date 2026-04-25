# Architecture Draft Reconciliation Plan

This document is the canonized reconciliation plan for the current
user-owned architecture and build-plan drafts under `docs/`.

It does not promote those draft files to repo truth on its own. Instead, it
maps each draft to the tracked docs it most likely feeds and recommends the
order to merge durable content without rewriting user-owned draft files in
place.

## Rules

- Treat the untracked draft docs as inputs, not canonized truth.
- Reconcile durable content into tracked docs in small, scoped follow-up edits.
- Prefer merging stable concepts into existing tracked docs over creating more
  overlapping architecture docs.
- Keep time-bound planning artifacts and prompt scaffolds out of the canonical
  architecture set unless their content is explicitly re-canonized.

## Current Tracked Baseline

The tracked architecture baseline currently centers on these docs:

- `docs/wrkflo-7layer-vision.md`
- `docs/architecture.md`
- `docs/current-implementation-vs-canonical.md`
- `docs/implementation-substrate.md`
- `docs/wrkflo-orchestration-architecture.md`
- `docs/governance.md`
- `docs/memory-architecture.md`

These are the primary destinations for durable architecture content from the
draft set.

## Draft-To-Baseline Map

| Draft doc | Primary tracked destination | Secondary tracked destinations | What to extract | What to leave out |
| --- | --- | --- | --- | --- |
| `docs/wrkflo-master-build-plan.md` | `docs/current-implementation-vs-canonical.md` | `docs/wrkflo-7layer-vision.md`, `docs/implementation-substrate.md`, `docs/governance.md` | Durable platform framing, phased target-topology direction, and clear boundary language between product model, runtime substrate, and governance | Duplicative roadmap prose, market sizing detail, or speculative framework comparisons that do not change the architecture baseline |
| `docs/build-brief.md` | `docs/wrkflo-orchestration-architecture.md` | `docs/architecture.md`, `docs/implementation-substrate.md` | The current "supervisor -> sub-orchestrators -> workers" operating model, Redis-first runtime sequencing, and Langflow/orchestrator boundary wording | "Locked roadmap" language and sprint-style sequencing that will go stale quickly |
| `docs/two-tier-orchestrator-pattern.md` | `docs/wrkflo-orchestration-architecture.md` | `docs/architecture.md` | The durable immortal-supervisor plus restartable-AI pattern, including the split of responsibilities between supervisor, AI coordinator, and watchdog | One-off incident narration except where it strengthens the rationale for the pattern |
| `docs/wrkflo-production-agent-architecture.md` | `docs/wrkflo-orchestration-architecture.md` | `docs/wrkflo-7layer-vision.md` | Agent role taxonomy, orchestration vocabulary, and durable execution-pattern language | Over-detailed role catalogs that do not affect the current baseline or target topology |
| `docs/wrkflo-smb-use-case-social-media.md` | `docs/wrkflo-7layer-vision.md` | `docs/current-implementation-vs-canonical.md` | A concrete example that explains how the seven-layer model behaves end to end with approvals and scheduled execution | Product-specific narrative detail that is better kept as an example than merged into core architectural definitions |
| `docs/openclaw-fleet-decision.md` | `docs/architecture.md` | `docs/governance.md`, `docs/wrkflo-orchestration-architecture.md` | The boundary that OpenClaw stays outside the local `tmux` fleet and connects through the orchestrator API as an external platform | Session metadata and connector-specific implementation detail that belongs in runbooks, not architecture docs |
| `docs/sprint-week-plan.md` | `docs/current-implementation-vs-canonical.md` | `docs/architecture.md` | Only durable sequencing insights, if they survive validation and are later canonized into the live workload or tracked roadmap material | Day-by-day worker plans and repo-task slices; those belong in workload control, not architecture truth |
| `docs/chatgpt-review-prompt.md` | No direct merge target | `docs/current-implementation-vs-canonical.md`, `docs/governance.md`, `docs/implementation-substrate.md` after review | Net-new findings produced from the prompt, once independently validated and rewritten as repo-owned conclusions | The prompt text itself; it is a review instrument, not architecture content |

## Suggested Reconciliation Order

1. Reconcile the umbrella framing first.
   Merge durable architecture and boundary language from
   `docs/wrkflo-master-build-plan.md` into
   `docs/current-implementation-vs-canonical.md`,
   `docs/wrkflo-7layer-vision.md`, and
   `docs/implementation-substrate.md` so the repo has one consistent story
   about product model, live stack, and target topology.

2. Reconcile the live orchestration model next.
   Merge `docs/build-brief.md`, `docs/two-tier-orchestrator-pattern.md`, and
   the durable parts of `docs/wrkflo-production-agent-architecture.md` into
   `docs/wrkflo-orchestration-architecture.md`, with only the operator-stack
   overlap that belongs in `docs/architecture.md`.

3. Reconcile connector and governance boundaries.
   Land the durable OpenClaw boundary from
   `docs/openclaw-fleet-decision.md` into `docs/architecture.md` and
   `docs/governance.md` so external-agent platforms are clearly separated from
   the local worker fleet.

4. Reconcile the canonical product example.
   Pull the strongest reusable example material from
   `docs/wrkflo-smb-use-case-social-media.md` into
   `docs/wrkflo-7layer-vision.md` as an example of how approvals,
   orchestration, and execution work across the seven layers.

5. Reconcile only the durable parts of planning drafts.
   Review `docs/sprint-week-plan.md` for sequencing lessons that remain true
   after implementation, but merge only validated insights and only after they
   are reflected in workload or tracked architecture docs.

6. Run external-review synthesis last.
   Use `docs/chatgpt-review-prompt.md` only to generate critique, then land
   validated findings into the appropriate tracked docs as repo-owned prose
   rather than preserving the prompt itself.

## Recommended Follow-Up Edit Slices

- Slice 1: framing and boundary cleanup
  Target `docs/current-implementation-vs-canonical.md`,
  `docs/wrkflo-7layer-vision.md`, and `docs/implementation-substrate.md`.

- Slice 2: orchestration model consolidation
  Target `docs/wrkflo-orchestration-architecture.md` and `docs/architecture.md`.

- Slice 3: connector and governance boundary clarification
  Target `docs/architecture.md` and `docs/governance.md`.

- Slice 4: canonical example landing
  Target `docs/wrkflo-7layer-vision.md`.

- Slice 5: validated planning deltas only
  Target whichever tracked architecture doc gains durable signal from
  `docs/sprint-week-plan.md`.

## Completion Criteria

This reconciliation lane is complete when:

- every current user-owned architecture/build-plan draft has a named tracked
  destination or an explicit "do not merge directly" outcome
- the merge order is clear enough to execute in small docs-only follow-up
  slices
- no reconciliation step requires editing the user-owned draft files directly
