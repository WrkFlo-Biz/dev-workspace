# Governance

Wrk-Flo separates governance and deployment control from runtime execution
control. Repository settings, CI pipelines, and runtime secrets should not be
collapsed into one trust boundary.

## Governance Spine

GitHub Enterprise is the governance and deployment spine for the platform.

| Plane | Primary system | Responsibility |
| --- | --- | --- |
| Source and review | GitHub Enterprise | repos, ADRs, pull requests, branch protection, code owners, release intent |
| CI/CD and promotion | GitHub Enterprise workflows and environment gates | build, verify, publish, and approve promotion between environments |
| Runtime platform | Azure | compute, networking, managed identities, Key Vault, public application surfaces |
| Execution control | wrkflo-orchestrator | workflow policy, approval tokens, audit events, task contracts |

## Secrets And Identity Boundary

GitHub Secrets is CI/CD-scoped only:

- use it for pipeline bootstrap, short-lived deployment credentials, or
  federated CI access
- do not treat it as the runtime application secret store
- do not make it the durable home for operator-only or tenant runtime secrets

Runtime secrets belong in Azure Key Vault, with managed identities as the
default runtime access path:

- App Service, workers, and other hosted components should read secrets through
  managed identity rather than shipping long-lived credentials
- local `.env` files are bootstrap conveniences for the dev workspace, not the
  target production pattern
- approval credentials, service credentials, and connection strings should move
  behind Key Vault references as the runtime hardens

## Promotion Model

1. GitHub Enterprise captures the intended change through PR review and branch policy.
2. CI verifies the change and produces versioned artifacts.
3. Environment approvals decide whether the artifact can move forward.
4. Azure deploys the approved runtime with managed identity and Key Vault references.
5. wrkflo-orchestrator records runtime approvals, lineage, and evidence in durable storage.

## Governance Guardrails

- Sensitive runtime actions require human approval and durable evidence.
- Runtime approval records belong in the durable data plane, not in CI metadata.
- External agents integrate through APIs and contracts; they do not inherit repo
  admin or cloud-admin privileges by default.
- OpenClaw is governed as an external connector: its deployed agents stay
  outside the local dev-workspace `tmux` fleet and use `wrkflo-orchestrator`
  API contracts instead of direct worker-session access.
- Platform documentation keeps canonical product architecture separate from
  implementation-substrate and deployment docs.
