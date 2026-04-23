# dev-workspace

Azure VM remote development infrastructure. Accessed from Mac (Terminal.app) and phone (Termius) via Tailscale mesh.

## Key directories
- scripts/dws-launcher.sh — two-step project+model picker with tmux persistence
- scripts/dws-health.sh — system health dashboard
- codex-profiles/ — Foundry profile configs for Codex CLI
- mac-setup/ — Mac-side LaunchAgents, Chrome CDP relay, Hammerspoon bridge
- infra/ — Azure Bicep VM template
- config/ — tmux.conf and shared dotfiles

## How to test
bash -n scripts/dws-launcher.sh && echo ok

## Integration
- All 6 Wrk-Flo projects live under ~/projects on the VM
- Codex profiles map to 12 Azure Foundry deployments on moses-8586-resource
- Mac bridges (CDP + Hammerspoon) let the VM control the Mac remotely
- Tailscale mesh: VM=100.117.16.63, Mac=100.78.207.22, Phone=100.88.249.22
