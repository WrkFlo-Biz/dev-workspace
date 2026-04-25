# Wrk-Flo Memory Architecture

Wrk-Flo separates logical memory tiers from physical storage roles. This keeps
the product architecture clear and prevents one storage technology from being
treated as the answer to every state problem.

## Logical memory tiers

| Tier | Scope | Examples |
| --- | --- | --- |
| Client-level | A single customer, tenant, or account | customer preferences, account-specific policies, prior approvals, business context |
| Domain-level | Shared within a workflow domain or vertical | support playbooks, finance procedures, sales qualification patterns |
| Platform-level | Shared platform intelligence and reusable patterns | orchestration templates, policy primitives, evaluation results, product heuristics |

## Physical storage roles

| Store | Role | What belongs there |
| --- | --- | --- |
| Redis | Hot coordination and ephemeral state | leases, locks, queues, rate limits, short-lived workflow coordination |
| Durable relational database | Immutable history and system truth | approvals, lineage, run history, audit records, durable contracts |
| Vector or retrieval store | Semantic lookup | client, domain, or platform memory retrieval based on meaning rather than exact keys |

## Boundary rules

- Redis is not the system of record for durable workflow history.
- Durable audit, approvals, and lineage do not belong in vector storage.
- Vector retrieval is for recall and context assembly, not authoritative
  transaction state.
- The same logical tier may span more than one physical store depending on the
  query pattern and retention requirement.

## Mapping the tiers to storage

| Logical tier | Primary durable truth | Retrieval support | Ephemeral runtime support |
| --- | --- | --- | --- |
| Client-level | relational records per tenant or client | client-specific retrieval index | Redis coordination during active workflows |
| Domain-level | relational workflow and policy records | domain retrieval collections | Redis for in-flight coordination and leases |
| Platform-level | durable platform metadata and audit | shared retrieval corpus | Redis for platform-wide coordination primitives |

## Dev-workspace boundary

The `dev-workspace` repo also carries operator metadata such as session state,
launcher state, and coordination scratch files. Those artifacts are part of the
implementation substrate and operator workflow, not the product memory model
described above.
