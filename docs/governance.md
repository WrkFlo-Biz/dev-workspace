# Wrk-Flo Governance Architecture

This document defines the platform-level governance boundary for Wrk-Flo. It is
separate from implementation details inside sibling runtime repos.

## Governance spine

GitHub Enterprise is the canonical governance and deployment spine:

- repositories, pull requests, and review policy live there
- Actions and environment controls govern CI/CD flow
- branch protection and release approval live there
- GitHub Secrets is CI/CD-scoped only

Runtime secrets do not belong in GitHub Secrets. Live services should obtain
runtime credentials through Azure Key Vault plus managed identities.

## Governance responsibilities

| Area | Primary system | Notes |
| --- | --- | --- |
| Source control and review | GitHub Enterprise | Canonical change history and approval boundary |
| CI/CD secret injection | GitHub Secrets | Build and deployment only |
| Runtime identity | Azure managed identities | Service-to-service auth without long-lived shared secrets |
| Runtime secret authority | Azure Key Vault | API keys, connection strings, signing material, and rotation |
| Human approvals | Product workflow controls | Tiered approvals, delegated authority, and audit evidence |
| Audit retention and lineage | Durable relational data store | Not Redis and not a CI/CD secret store |

## Relationship to the canonical seven layers

Governance remains part of the canonical layer 7 trust boundary. The cloud or
deployment substrate that implements those controls is not a new public layer.

## Azure-first implementation path

The current platform narrative is Azure-first:

- Azure VM for the operator workspace and development substrate
- Azure AI Foundry for model access
- Azure Key Vault plus managed identities for runtime secrets and identity
- Azure App Service as the current planned public-surface step
- Front Door or Application Gateway only if later public exposure requires WAF
  or routing controls

Cloudflare is not part of the current implementation path.

## What this repo does and does not own

`dev-workspace` owns the platform narrative, governance positioning, and
operator substrate docs.

`wrkflo-orchestrator` and other sibling repos own runtime-specific
implementation contracts, ADRs, and service behavior.
