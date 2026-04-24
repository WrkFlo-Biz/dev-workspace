# Secrets Boundary

This document defines which session classes should carry which credentials on
the dev-workspace VM.

## Credential Sources

| Secret / access | Source | Notes |
| --- | --- | --- |
| `AZURE_OPENAI_API_KEY` | `~/.config/wrkflo/foundry.env` | Used by Codex/Foundry profiles. |
| GitHub auth | `gh auth login` plus normal git credential flow | Not loaded from `foundry.env`. |
| Azure CLI auth | `az login` | Needed to fetch or rotate Foundry keys and for Azure admin work. |
| Mac bridge access | `MAC_SSH_HOST`, `MAC_CDP_URL`, `MAC_GUI_URL` | Tailscale-reachable paths to the Mac SSH, Chrome CDP, and Hammerspoon bridges. |

## Session Classes

### Foundry-only sessions

Default case:
launcher-created Codex or Foundry sessions such as `gs-5-4`, `dws-5-4`, or any
host-local worker session that the installed runtime happens to create.

- These sessions should only need `AZURE_OPENAI_API_KEY`.
- They are the right place for normal repo edits, local tests, shell work, and
  most focused implementation tasks.
- They should not be treated as the place to keep GitHub admin auth, Azure
  admin state, or Mac bridge access unless the task explicitly requires it.

### GitHub + Azure sessions

Primary control-plane session:
`orchestrator`.

- Treat the orchestrator as the session that may need both Foundry access and
  host GitHub auth because it coordinates cross-repo work, reviews worker
  output, and is the most likely place to stage, commit, push, or inspect
  GitHub state.
- Azure CLI auth should stay concentrated here when the task is key rotation,
  deployment, or Foundry admin work.
- `foundry.env` still only provides `AZURE_OPENAI_API_KEY`; GitHub and Azure
  CLI auth are separate host-level login states.

### Privileged bridge sessions

Any ad hoc session used for Mac control:
`scripts/control-mac-gui.py`, Chrome CDP work, `dws-sync-mac.sh`,
Termius/Mac repair flows, or direct bridge debugging.

- These sessions need `MAC_SSH_HOST`, `MAC_CDP_URL`, and/or `MAC_GUI_URL`.
- They should be treated as higher-risk because they can drive the Mac over
  Tailscale and may trigger OS-level actions through Hammerspoon or Chrome.
- Keep them separate from ordinary worker sessions when possible.

## How `foundry.env` Loads

`scripts/dws-sessions-init.sh` no longer spawns a managed Codex pool in the
checked-in repo. It performs lightweight boot prep for the on-demand model.

Ad hoc launcher sessions from `scripts/dws-launcher.sh` and
`scripts/dws-quick.sh`:

- load `AZURE_OPENAI_API_KEY` only if it is not already set
- export the Mac bridge vars (`MAC_GUI_URL`, `MAC_CDP_URL`, `MAC_SSH_HOST`)
  into the session wrapper

Login shells on the VM:

- `vm-bootstrap.sh` and the setup docs wire `~/.bashrc` / `~/.profile` to
  source `~/.config/wrkflo/foundry.env`

## Recommendation: Low-privilege Worker Mode

For docs, test, grep, shellcheck, local bash tests, and other repo-local tasks
that do not need remote model calls or API access:

- prefer a low-privilege worker mode that does **not** source `foundry.env`
- do **not** rely on `gh auth`, `az login`, or the Mac bridge vars
- prefer plain shell work or structured local execution via
  `scripts/dws-worker-exec.sh`

In practice, keep the general worker pool as narrow as possible and only move a
task into orchestrator or Mac-control sessions when the task truly needs those
extra credentials.
