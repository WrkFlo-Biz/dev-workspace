# Wrk-Flo Implementation Substrate

This document describes the current infrastructure runtime beneath the canonical
Wrk-Flo seven-layer product architecture.

It is intentionally separate from the public seven layers. There is no new
public "Layer 0" in the canonical model.

## Current Azure-first substrate

| Area | Current path | Notes |
| --- | --- | --- |
| Operator workspace | Azure VM + Ubuntu + Tailscale + `tmux` | Current development and operator entrypoint |
| Model access | Azure AI Foundry | Current model-routing and provider access path |
| Governance and deployment | GitHub Enterprise + GitHub Actions | GitHub Secrets stays CI/CD-scoped |
| Runtime identity and secrets | Azure managed identities + Azure Key Vault | Target runtime authority for live services |
| Public application surface | Azure App Service | Current planned first hosted public-surface step |
| Edge / WAF / global routing | Front Door or Application Gateway later if required | Not a current requirement for the Azure-first path |

Cloudflare is not part of the current implementation path.

## Why this stays separate from the canonical seven layers

The seven layers describe product responsibilities. The implementation substrate
describes where and how those responsibilities are currently deployed.

Changing the substrate should not force a rewrite of the canonical product
architecture unless the product behavior itself changes.

## Target production topology

The expected production shape separates:

- user-facing application surfaces
- orchestration and workflow control-plane services
- Redis-backed coordination and short-lived runtime state
- durable relational history, approvals, and lineage
- retrieval and vector indexes for memory lookup

This separation is important for reliability, auditability, and future vendor
portability even while the near-term implementation path stays Azure-first.

## Repo boundary

`dev-workspace` documents the operator environment and the platform narrative.
Sibling repos own concrete service contracts and implementation ADRs.
