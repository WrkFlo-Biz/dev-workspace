# dev-workspace launcher

The launcher is what makes "tap VM host in Termius" feel like "I'm in codex on
Global Sentinel with Foundry already wired up." It runs automatically on every
interactive SSH login to `dev-workspace-vm`.

## What it does

1. Sources `~/.profile` — loads `AZURE_OPENAI_API_KEY` from
   `~/.config/wrkflo/foundry.env` into the shell env.
2. Verifies Tailscale is reachable + repos are present.
3. Shows a numbered picker:

   ```
   ⎈ dev-workspace  ·  moses@dev-workspace-vm  ts=100.117.16.63
      Azure Foundry: moses-8586-resource (eastus2)  key=ok

    1  Global Sentinel    — codex (gpt-5.2-codex)
    2  Global Sentinel    — codex (gpt-5.4 xhigh)
    3  Global Sentinel    — Claude Code
    4  Voice Agents       — codex (gpt-5.2-codex)
    5  OpenClaw           — codex (gpt-5.2-codex)
    6  GS Azure Quantum   — codex (gpt-5.2-codex)
    7  Orchestrator       — codex full-access (gpt-5.4)
    8  Plain shell in ~/projects
    9  Tailscale / system status
    q  quit / drop to bash
   ```

4. When you pick a project, it starts from `~/projects`, sets
   `DWS_PRIMARY_PROJECT=<name>`, and `exec`'s the chosen tool with access to
   `$HOME`. The launched agent starts with the selected project as its primary
   focus but may inspect sibling projects when the task calls for it.

## Files

- `scripts/dws-launcher.sh` — the picker (committed here, lives at
  `~/bin/dws-launcher.sh` on the VM).
- `~/.bash_profile` on the VM — runs the picker on interactive TTY logins.
- `~/projects/` on the VM — symlinks + clones of every Wrk-Flo repo in one place.

## Workspace targets

- `global-sentinel` — primary geopolitical/macro intelligence runtime.
- `wrkflo-voice-agents-ops` — voice-agent audit, safety, and runbook work.
- `openclaw-prod` — OpenClaw gateway/runtime/deploy work.
- `global-sentinel-azure-quantum` — quantum experiments and related notes.
- `wrkflo-orchestrator` — central multi-agent control plane and workflow
  coordination project.
- `dev-workspace` — VM, launcher, Mac bridge, Tailscale, and operator tooling.

## Escape hatches

- Type `q` or press Enter at the picker → plain bash shell.
- `ssh -o 'SetEnv SKIP_LAUNCHER=1' dev-workspace-vm` → skip entirely.
- `ssh dev-workspace-vm <command>` → non-TTY, picker never runs.

## Adding a new project

Edit `scripts/dws-launcher.sh`, add a line to the menu and a case. Then:

```bash
scp scripts/dws-launcher.sh moses@dev-workspace-vm:~/bin/dws-launcher.sh
```

(Symlink `~/projects/<name>` → the repo if it lives elsewhere on the VM.)
