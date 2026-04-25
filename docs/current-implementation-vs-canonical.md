# Current Implementation vs Canonical Architecture

Wrk-Flo keeps three architecture views separate so the public product model
does not get polluted by temporary runtime details.

## Three Architecture Views

| View | Answers | Primary docs |
| --- | --- | --- |
| Canonical product architecture | What the product is | [wrkflo-7layer-vision.md](./wrkflo-7layer-vision.md) |
| Current implementation stack | How the current operator/runtime environment works | [architecture.md](./architecture.md), [wrkflo-orchestration-architecture.md](./wrkflo-orchestration-architecture.md), [implementation-substrate.md](./implementation-substrate.md) |
| Target production topology | How the hosted control plane, data plane, and governance boundary should land | [governance.md](./governance.md), [memory-architecture.md](./memory-architecture.md), [implementation-substrate.md](./implementation-substrate.md) |

## Side-By-Side Alignment

| Concern | Canonical product architecture | Current implementation stack | Target production topology |
| --- | --- | --- | --- |
| Layer model | Seven public layers, provider-agnostic | Azure VM, Tailscale, `tmux`, `wrkflo-orchestrator`, and operator tooling | Hosted services, explicit data-plane boundaries, and public surfaces |
| Orchestration | chief orchestrator, sub-orchestrators, specialist agents | `orchestrator-supervisor.sh`, `orch-agent`, workload file, worker panes | durable orchestration service with typed runtime contracts |
| Workflow authoring vs runtime | authoring surfaces and runtime control stay separate | Langflow handles workflow templates and visual authoring; `wrkflo-orchestrator` owns runtime execution, state, approvals, retries, audit, and policy | authored flows hand off into typed runtime contracts instead of making the builder the execution system of record |
| Interfaces | chat, voice, dashboard, widget, API/CLI surfaces | SSH launcher, Termius, `tmux`, phone callback server | App/web/mobile-facing surfaces over hosted APIs |
| Memory and state | product capability for state, evidence, and reusable memory | workload file, coordination log, review snapshot, append-only local state | Redis for hot coordination, durable relational DB for truth, vector/retrieval store for lookup |
| Governance and secrets | security, approvals, compliance, deployment controls | GitHub Enterprise spine, CI/CD secrets, local bootstrap env files still present | GitHub Enterprise + environment approvals + Azure Key Vault + managed identities |
| Public ingress | product can expose APIs and approval surfaces | operator-only SSH path plus local API services | App Service first, Front Door or Application Gateway later if WAF/routing/public exposure requires it |
| External systems | tools and partner connectors via contracts | repo/github/browser/cli adapters and Mac-side bridges | typed connectors, MCP surfaces, and external agent platforms over API |

## Boundary Rules

- Do not create a public "Layer 0" for cloud or vendor choices.
- Keep the canonical seven layers provider-agnostic.
- Treat Langflow as an authoring and template surface, not the runtime source of
  truth; execution authority belongs to `wrkflo-orchestrator`.
- Put Azure, GitHub Enterprise, Key Vault, deployment topology, and network
  decisions in implementation-substrate and governance docs.
- Treat `tmux` and the current VM fleet as implementation adapters, not the
  long-term product contract.
