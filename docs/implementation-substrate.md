# Implementation Substrate

This document describes the current Azure-first runtime substrate beneath the
canonical Wrk-Flo seven-layer product architecture. It is not a public "Layer
0"; it is the deployment and infrastructure boundary that supports the layers.

## Core Rules

- Keep the canonical seven layers provider-agnostic.
- Put cloud, networking, runtime, and deployment decisions here.
- Keep GitHub Enterprise as the governance and deployment spine.
- Keep runtime secrets in Azure Key Vault with managed identities.

## Current Azure-First Path

| Area | Current direction |
| --- | --- |
| Operator access | Tailscale, MagicDNS, SSH, and `tmux` on the Azure VM |
| Source and release control | GitHub Enterprise with workflow and environment gates |
| Model/runtime bootstrap | Azure AI Foundry-backed profiles in the operator environment |
| Control plane | `wrkflo-orchestrator` HTTP API and worker runtime |
| Workflow authoring | Langflow for template and builder workflows |
| Public application surface | Azure App Service is the current planned first hosted step |
| Hot coordination | Redis for queue state, leases, TTL caches, and ephemeral coordination |
| Durable truth | relational storage for approvals, lineage, immutable history, and audit |
| Retrieval memory | vector or retrieval store for semantic lookup across reusable memory |

## Public Surface Boundary

- Azure App Service is the current planned public-surface step.
- Front Door or Application Gateway may be added later if WAF, routing, or
  broader public exposure requires them.
- Cloudflare is not part of the current Azure-first implementation path.

## Execution Boundary

- `tmux` is a current operator/runtime adapter, not the product architecture.
- External runtimes such as OpenClaw integrate through APIs rather than joining
  the local worker fleet as first-class tmux sessions.
- The current VM and session fleet prove orchestration patterns, but the target
  runtime contract is typed services plus hosted workers, not a permanent VM
  dependency.

## What Stays Out Of The Canonical 7 Layers

- vendor names and cloud products
- VM topology and session-management details
- CI/CD and environment-promotion mechanics
- secrets-storage implementation details
