# Memory Architecture

Wrk-Flo separates storage roles from logical memory tiers. "Memory" is not one
database; it is a set of distinct responsibilities with different performance,
retention, and audit requirements.

## Storage Roles

| Store | Responsibility | Typical examples | What it is not |
| --- | --- | --- | --- |
| Redis | hot coordination, leases, TTL caches, ephemeral runtime state | task claims, approval pending indexes, rate limits, circuit state | durable system of record |
| Durable relational DB | immutable truth, approvals, lineage, audit, terminal run history | approval receipts, state transitions, workflow lineage, audit evidence | disposable cache |
| Vector or retrieval store | semantic lookup over reusable knowledge | embedded documents, client memory retrieval, domain playbook search, policy lookup | authoritative ledger of record |

## Logical Memory Tiers

| Tier | Scope | Examples |
| --- | --- | --- |
| Client-level | tenant- or client-specific memory | operating preferences, prior approvals, reusable client artifacts, account-specific retrieval corpus |
| Domain-level | reusable memory for a vertical or function | sales playbooks, finance controls, support procedures, content templates |
| Platform-level | cross-cutting platform memory and policy | routing heuristics, benchmark results, safety policies, common tool guidance |

## Mapping Tiers To Stores

| Tier | Durable truth | Retrieval view | Hot runtime state |
| --- | --- | --- | --- |
| Client-level | client approvals, lineage, and immutable run history | client-specific semantic lookup | active leases, pending actions, short-lived coordination |
| Domain-level | versioned workflow specs and domain evidence | reusable domain knowledge and playbooks | in-flight task coordination for that domain |
| Platform-level | policy records, benchmark lineage, shared governance evidence | cross-platform guidance and retrieval indexes | global routing hints, short-lived rate-limit buckets, coordination caches |

## Current vs Target

Today, some bootstrap state still lives in local SQLite files, append-only logs,
and repo-local artifacts. Treat those as transitional implementation details for
the current operator environment.

The target boundary is:

- Redis for hot coordination and ephemeral state
- durable relational storage for approvals, lineage, immutable history, and
  audit
- vector or retrieval storage for semantic memory lookup across client, domain,
  and platform tiers

Redis should accelerate the system; it should not become the source of truth for
approvals, audit, or long-term memory.
