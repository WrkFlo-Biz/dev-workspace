# Architecture Draft Index

This file is the canonized index for the architecture and build-plan draft
documents currently present under `docs/`.

It does two things:

- inventories the current user-owned draft docs without editing them
- points back to the tracked docs that currently anchor repo truth

## Working Rules

- Treat the draft files listed below as working inputs, not canonized repo
  truth.
- Treat the tracked architecture docs in the second table as the current
  checked-in baseline.
- If a draft graduates, land its durable content into the appropriate tracked
  doc or ADR rather than relying on this index alone.

## User-Owned Draft Docs

All files in this section are currently untracked in `git status` and should be
treated as user-owned inputs.

| File | Working role | Current signal | Suggested use |
| --- | --- | --- | --- |
| `docs/build-brief.md` | Locked implementation roadmap | Defines the current "main orchestrator -> sub-orchestrators -> workers" build sequence, Langflow/orchestrator boundary, and Redis-first phase ordering | Use as the strongest execution-roadmap draft if a single build sequence is needed |
| `docs/chatgpt-review-prompt.md` | External review scaffold | Prompt text for a critical architecture/build-plan review pass | Use as review input, not as architecture truth |
| `docs/openclaw-fleet-decision.md` | Boundary decision note | States that OpenClaw stays outside the `tmux` fleet and connects through the orchestrator API | Use as a connector-boundary decision memo |
| `docs/sprint-week-plan.md` | Parallel sprint sketch | Seven-day worker-by-worker sprint plan with concrete task slices | Treat as a planning snapshot unless its task list is re-canonized into the live workload |
| `docs/two-tier-orchestrator-pattern.md` | Reusable orchestration pattern | Captures the immortal supervisor + restartable AI coordinator pattern proven on 2026-04-25 | Use as a pattern note that can be cited by future orchestration docs |
| `docs/wrkflo-master-build-plan.md` | Umbrella build-plan draft | Aggregates architecture, research findings, platform positioning, and phased build direction | Use as the broadest product-and-build draft |
| `docs/wrkflo-production-agent-architecture.md` | Agent role taxonomy draft | Defines production agent roles, distributed-systems patterns, and target workflow structure | Use when refining agent-role and orchestration design language |
| `docs/wrkflo-smb-use-case-social-media.md` | Canonical product example draft | Works through an end-to-end SMB social-media approval flow across the seven layers | Use as a concrete narrative example for product and orchestration discussions |

## Tracked Architecture Baseline

These files are already tracked and are the current repo-backed reference set.

| File | Current role |
| --- | --- |
| `docs/wrkflo-7layer-vision.md` | Canonical provider-agnostic product architecture |
| `docs/architecture.md` | Current live `dev-workspace` implementation stack |
| `docs/current-implementation-vs-canonical.md` | Alignment map between canonical model, live stack, and target topology |
| `docs/implementation-substrate.md` | Azure-first runtime and deployment substrate |
| `docs/wrkflo-orchestration-architecture.md` | Current live multi-agent orchestration stack |
| `docs/governance.md` | Governance, deployment, and execution-control boundary |
| `docs/memory-architecture.md` | Storage-role and memory-tier model |

## Suggested Reading Order

1. Read `docs/wrkflo-7layer-vision.md` for the stable product model.
2. Read `docs/architecture.md`, `docs/current-implementation-vs-canonical.md`,
   `docs/implementation-substrate.md`, and
   `docs/wrkflo-orchestration-architecture.md` for live-stack truth.
3. Read `docs/wrkflo-master-build-plan.md` and `docs/build-brief.md` for the
   largest build-plan drafts.
4. Read `docs/wrkflo-production-agent-architecture.md`,
   `docs/wrkflo-smb-use-case-social-media.md`,
   `docs/openclaw-fleet-decision.md`, and
   `docs/two-tier-orchestrator-pattern.md` for design-pattern and example
   depth.
5. Read `docs/sprint-week-plan.md` only as a draft planning artifact unless
   its tasks are explicitly re-canonized into the live workload.
