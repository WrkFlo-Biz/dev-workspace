# Azure AI Foundry wiring

All Codex profiles in this repo route to deployments on one AI Services resource.

## Resource

- **Name**: `moses-8586-resource`
- **Kind**: `AIServices` (Azure AI Foundry hub)
- **Resource group**: `rg-moses-8586`
- **Region**: `eastus2`
- **Endpoint**: `https://moses-8586-resource.cognitiveservices.azure.com`

## Deployments and which profile maps to each

| Deployment            | Version      | Codex profile         | Best for                                      |
|-----------------------|--------------|-----------------------|-----------------------------------------------|
| `gpt-5.4`             | 2026-03-05   | `foundry-5_4`         | Hard problems, architecture, cross-cutting    |
| `gpt-5.2`             | 2026-01-14   | *(migration target of `gpt-5.2`)* | General purpose                       |
| `gpt-5.2-codex`       | 2026-01-14   | `foundry` *(default)* | Day-to-day coding                             |
| `gpt-5.1-codex-mini`  | 2025-11-13   | `foundry-mini`        | Small edits, cheap iterations                 |
| `gpt-5-mini`          | —            | *(via SDKs)*          | Lightweight service code, embeddings callers  |
| `gpt-4o`              | —            | `foundry-4o`          | Multimodal (images, long docs)                |
| `gpt-realtime`        | —            | *(WS protocol only)*  | Voice agents (see below)                      |
| `gpt-realtime-mini`   | —            | *(WS protocol only)*  | Cheaper voice agents                          |
| `claude-opus-4-6`     | —            | `foundry-opus`        | Second-opinion reviewer, strategic reasoning  |
| `claude-sonnet-4-6`   | —            | `foundry-sonnet`      | Balanced Claude use                           |
| `claude-haiku-4-5`    | —            | *(via SDKs)*          | Cheap, fast Claude tasks                      |
| `text-embedding-3-small` | —         | *(embeddings only)*   | Memory/vector search in apps                  |

All GlobalStandard SKUs. Regional ceiling in eastus2 is 10,000 TPM per model;
each deployment currently sits at 2,000 TPM. Scale with:

```bash
az cognitiveservices account deployment create \
  -g rg-moses-8586 -n moses-8586-resource \
  --deployment-name <name> --model-name <name> --model-version <ver> \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity <N>
```

(Note: `az` has no `deployment update` verb — the above upserts.)

## API key

Key is fetched on-demand with `az cognitiveservices account keys list`.

- **VM**: persisted to `~/.config/wrkflo/foundry.env` (chmod 600), auto-loaded by
  `~/.bashrc` and `~/.profile` as `AZURE_OPENAI_API_KEY`. Same pattern as existing
  `ANTHROPIC_FOUNDRY_API_KEY`.
- **Mac**: **no key at rest.** `~/.zshrc` defines `codex-foundry()` which calls
  `az` at launch and exports the key inline. Requires an active `az login` session.

## Voice / realtime

Codex CLI does not speak the realtime protocol. Connect from app code instead:

```
wss://moses-8586-resource.cognitiveservices.azure.com/openai/realtime
  ?api-version=2024-10-01-preview
  &deployment=gpt-realtime
```

Auth via `api-key: $AZURE_OPENAI_API_KEY` header. Azure docs:
<https://learn.microsoft.com/azure/ai-services/openai/realtime-audio-quickstart>.

## Known trap: model migrations

Codex has `[notice.model_migrations]` that silently rewrites model names in
outgoing requests. **Never** add `gpt-5.2-codex` or `gpt-5.1-codex-mini` to
that map — if codex rewrites the name to something that isn't deployed on
Foundry, every call 404s with "The API deployment for this resource does not exist".
