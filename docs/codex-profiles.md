# Foundry Codex Profiles

These are the 9 Azure Foundry-backed Codex profiles used by the launcher.
In this repo, each Azure deployment name matches the model name.

| Profile | Model | Tier | Best use case | Azure deployment |
| --- | --- | --- | --- | --- |
| `foundry-5_4` | `gpt-5.4` | `xhigh` | Hard bugs, architecture, planning | `gpt-5.4` |
| `foundry-5_2` | `gpt-5.2` | `high` | General coding and solid all-around work | `gpt-5.2` |
| `foundry-codex` | `gpt-5.2-codex` | `high` | Day-to-day coding and code-heavy tasks | `gpt-5.2-codex` |
| `foundry-mini` | `gpt-5.1-codex-mini` | `med` | Quick edits and cheap iterations | `gpt-5.1-codex-mini` |
| `foundry-5-mini` | `gpt-5-mini` | `med` | Fast, cheap lightweight work | `gpt-5-mini` |
| `foundry-4o` | `gpt-4o` | `med` | Multimodal work, images, long docs | `gpt-4o` |
| `foundry-opus` | `claude-opus-4-6` | `high` | Complex reasoning and second-opinion reviews | `claude-opus-4-6` |
| `foundry-sonnet` | `claude-sonnet-4-6` | `med` | Balanced Claude use for general work | `claude-sonnet-4-6` |
| `foundry-haiku` | `claude-haiku-4-5` | `med` | Fast Q&A and lightweight tasks | `claude-haiku-4-5` |

## Add A New Profile

1. Create the profile dir: `mkdir -p ~/.config/codex/profiles/`
2. Copy the template: `cp ~/projects/dev-workspace/codex-profiles/foundry-profiles.toml ~/.config/codex/profiles/foundry-profiles.toml`
3. Add a new `[profiles.<name>]` block with `model`, `model_provider = "azure-foundry"`, and `model_reasoning_effort`.
4. Set `model` to the Azure deployment name you created in Foundry.
5. Use the new profile with `codex --profile <name>`.
