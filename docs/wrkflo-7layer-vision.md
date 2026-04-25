---
name: Wrk-Flo 7-Layer Product Vision
description: Canonical Wrk-Flo architecture for SMB AI workflow OS — 7 layers, positioning, moat structure, and production path from current dev prototype to enterprise platform
type: project
originSessionId: 3dcbe974-5fb5-4591-8353-cecc0be17ae8
---
## Positioning

Wrk.Flo is an **implementation-grade AI workflow OS for SMBs**: a multi-agent, multi-model, multi-modal operating layer that turns messy business inputs into executed workflows, with orchestration, trust controls, and continuous monitoring built in.

## Canonical Boundaries

- This document is the provider-agnostic product model.
- The canonical public architecture remains seven layers.
- Infrastructure, cloud, and deployment choices belong in the implementation
  substrate, not in a public "Layer 0".

## Architecture Framing

1. Canonical product architecture: this document
2. Current implementation stack: Azure-first substrate and operator environment
3. Target production topology: public surfaces, control-plane services, memory
   stores, and governance controls deployed with clear boundaries

Reference docs:

- [current-implementation-vs-canonical.md](./current-implementation-vs-canonical.md)
- [implementation-substrate.md](./implementation-substrate.md)
- [governance.md](./governance.md)
- [memory-architecture.md](./memory-architecture.md)

## Canonical 7 Layers

1. **Interfaces**: chat, voice, dashboards, widgets, operator console, API/CLI
2. **Chief orchestrator**: receives goals, loads context, selects workflows, supervises execution
3. **Sub-orchestrators**: domain coordinators (sales ops, finance ops, support ops, content ops)
4. **Specialist agents**: planner, learner, tool-operator, critic, presenter, domain workers
5. **Tool/integration fabric**: CRM, ERP, calendar, email, telephony, browser,
   docs, repos, APIs, MCP
6. **Memory/state/evidence**: project registry, workflow state, retrieval,
   approvals, run history, lineage, and audit evidence
7. **Security/governance/compliance**: least privilege, approval tiers, tenant
   isolation, auditability, trust controls, and compliance posture

Layer 6 describes product capability, not one storage engine. In the current
architecture direction:

- Redis handles hot coordination and ephemeral runtime state
- durable relational storage handles approvals, lineage, history, and audit
- vector or retrieval stores handle semantic memory lookup

## Implementation Substrate

The current implementation path is Azure-first, but that is a deployment choice
outside the canonical seven layers:

- GitHub Enterprise is the governance and deployment spine
- GitHub Secrets is CI/CD-scoped only
- Azure Key Vault plus managed identities is the target runtime secret model
- Azure App Service is the current planned public-surface step
- Front Door or Application Gateway may be added later if public routing or WAF
  needs increase
- Cloudflare is not part of the current Azure-first path

## Memory Boundary

Wrk-Flo separates storage roles from logical memory tiers:

- Redis handles hot coordination, leases, caches, and ephemeral runtime state
- durable relational storage handles approvals, immutable history, lineage, and
  audit evidence
- vector or retrieval stores handle semantic lookup across reusable memory

The logical tiers remain:

- client-level memory
- domain-level memory
- platform-level memory

See [memory-architecture.md](./memory-architecture.md) for the storage and tier
boundary in detail.

## Moat Layers

1. Proprietary multi-agent orchestration platform
2. Operational intelligence learned from real deployments
3. Verticalized template library
4. Platform network effects (marketplace, partners, certified templates)

## Chief Orchestrator Role

- Receives goal
- Loads business/user/workflow context
- Selects sub-orchestrator or workflow
- Supervises execution
- Mediates approvals
- Synthesizes final result

## Sub-Orchestrator Role

- Scoped by domain (sales ops, finance ops, support ops, content ops)
- Breaks domain workflow into steps
- Manages specialist workers
- Handles local retries and sequencing
- Escalates Tier-2/3 actions upward

## Specialist Agent Taxonomy

- Planner
- Learner/retriever
- Tool operator
- Critic/verifier
- Presenter
- Domain-specific vertical agents

## Target Markets (in order)

1. SMBs, business owners, one-person teams — need problems solved immediately, not automation building
2. Growing businesses — need operational scaling without proportional headcount
3. Enterprise — need compliance, governance, audit, tenant isolation, SSO/RBAC

**Why:** User explicitly stated the path: SMB-ready first, then enterprise-grade. SMBs don't want to build automation — they want their specific problem solved. Enterprise layer adds compliance, governance, security, tenant isolation.

**How to apply:** When building Wrk-Flo features, always ask "does a one-person business owner need this?" first. Enterprise features (RBAC, tenant isolation, audit exports) come after the core workflow execution is solid.
