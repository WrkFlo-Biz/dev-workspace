# From-Scratch Setup Guide

This guide takes a fresh Ubuntu Azure VM to a working `dev-workspace` install
with:

- Azure VM provisioned from `infra/dev-workspace-vm.bicep`
- Tailscale online with MagicDNS and optional Tailscale SSH
- SSH hardened for key-only access
- repo scripts deployed into `~/bin`
- optional user `systemd` services installed
- cron installed for health checks, plus the optional managed cron block
- phone access through Termius

The current expected VM user is `moses` and the current hostname is
`dev-workspace-vm`. Adjust those if you intentionally diverge.

## 1. Prerequisites

You need all of the following before the build is complete:

- an Azure subscription with permission to create a resource group, VM, VNet,
  NIC, NSG, and public IP
- access to the private `Wrk-Flo/*` GitHub repos
- a Tailscale account on the same tailnet you will use from the Mac and phone
- an SSH keypair on your operator machine, usually `~/.ssh/id_ed25519`
- Azure CLI (`az`) and GitHub CLI (`gh`) on the operator machine

Verify the SSH public key you plan to inject into Azure:

```bash
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

## 2. Provision the Azure VM

`infra/dev-workspace-vm.bicep` is the source of truth for the VM shape. It
creates an Ubuntu 24.04 VM named `dev-workspace-vm` with a static public IP and
an NSG rule that allows inbound `22/tcp`.

Example deployment:

```bash
az login
az group create -n dev-ws-westus2 -l westus2

az deployment group create \
  -g dev-ws-westus2 \
  -f infra/dev-workspace-vm.bicep \
  -p adminUsername=moses \
  -p adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

Capture the public IP from the deployment output, then use that IP for the very
first SSH login before Tailscale is up:

```bash
ssh moses@<public-ip>
```

Important: the Bicep file intentionally leaves public SSH open. Do not treat
the VM as finished until Tailscale and SSH hardening are in place.

## 3. Clone the Repo and Run the VM Bootstrap

On the VM, get this repo into `~/projects/dev-workspace` with any authenticated
clone method. Example if GitHub SSH is already configured on the VM:

```bash
mkdir -p ~/projects
cd ~/projects
git clone git@github.com:Wrk-Flo/dev-workspace.git
cd ~/projects/dev-workspace
~/projects/dev-workspace/bin/vm-setup.sh
```

If GitHub SSH is not set up on the VM yet, clone over HTTPS or copy your
existing checkout to `~/projects/dev-workspace` and continue from there.

What `vm-setup.sh` does today:

- installs Ubuntu packages such as `tmux`, `openssh-server`, `cron`, `jq`,
  Python, Node.js, `gh`, `az`, and unattended upgrades
- installs Tailscale, Codex CLI, and Claude Code
- generates an SSH key if the VM does not already have one
- writes SSH hardening to
  `/etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf`
- clones the sibling Wrk-Flo repos into `~/projects`
- copies `config/tmux.conf` to `~/.tmux.conf`
- deploys `dws-launcher.sh`, `dws-health.sh`, `dws-health-check.sh`, and
  `dws-notify.sh` into `~/bin`
- updates `~/.bash_profile` so interactive SSH logins land in the launcher
- installs the simple 15-minute health-check cron entry
- installs any `wrkflo-orchestrator` user units found under
  `~/projects/wrkflo-orchestrator/ops/systemd`

The script is idempotent. If it stops because `gh` is not authenticated yet,
run `gh auth login` and rerun the same command.

## 4. Authenticate GitHub and Azure on the VM

After `vm-setup.sh` has installed the CLIs, finish the operator auth steps:

```bash
gh auth login
az login
```

Then create the Azure Foundry env file expected by the launcher and status
scripts:

```bash
mkdir -p ~/.config/wrkflo

KEY="$(az cognitiveservices account keys list \
  -g rg-moses-8586 \
  -n moses-8586-resource \
  --query key1 -o tsv)"

cat > ~/.config/wrkflo/foundry.env <<EOF
export AZURE_OPENAI_API_KEY="$KEY"
EOF

chmod 600 ~/.config/wrkflo/foundry.env
```

If you skipped `vm-setup.sh`, merge the repo Codex profiles manually:

```bash
~/projects/dev-workspace/scripts/apply-codex-profiles.sh
```

Verify the main tools:

```bash
codex --version
claude --version
gh auth status
az account show >/dev/null && echo "az ok"
```

## 5. Bring Up Tailscale

Install and enablement happen in `vm-setup.sh`; the remaining step is joining
the tailnet:

```bash
sudo tailscale up --ssh --operator="$USER" --hostname=dev-workspace-vm
```

Approve the auth URL that command prints, then verify:

```bash
tailscale status
tailscale ip -4
hostname
```

Expected result:

- the VM appears in the tailnet as `dev-workspace-vm`
- you can reach it over MagicDNS as `dev-workspace-vm`
- Tailscale SSH is enabled because of `--ssh`

Operational rule: once Tailscale is working, use `ssh moses@dev-workspace-vm`
as the primary access path. Keep the public IP only as a fallback.

## 6. Confirm SSH Hardening

`vm-setup.sh` writes the current hardening drop-in to:

```text
/etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf
```

The managed settings are:

- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- `PermitRootLogin no`
- `PubkeyAuthentication yes`
- `ClientAliveInterval 300`
- `ClientAliveCountMax 2`

Before you close the original public-IP session:

1. Confirm the config parses cleanly.
2. Open a second session over Tailscale or the public IP.
3. Only close the original shell after the second login succeeds.

Commands:

```bash
sudo sshd -t
sudo systemctl status ssh --no-pager || sudo systemctl status sshd --no-pager
```

Optional but recommended after Tailscale is proven: restrict inbound access to
the Tailscale subnet at the host firewall layer.

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --dry-run
sudo ~/projects/dev-workspace/bin/dws-firewall.sh
```

Do that only after you have already confirmed the Tailscale path works.

## 7. Deploy Repo Scripts into `~/bin`

The script layout matters:

- `scripts/` is the canonical source
- `bin/` is only a repo-local wrapper layer
- `~/bin/` is for scripts that must exist outside the repo checkout

`vm-setup.sh` already copies these into `~/bin`:

- `dws-launcher.sh`
- `dws-health.sh`
- `dws-health-check.sh`
- `dws-notify.sh`

For other scripts that must live in `~/bin`, symlink directly to `scripts/`,
not to repo `bin/`. The repo wrappers use relative paths and will break if you
symlink them into `~/bin`.

Useful symlinks:

```bash
mkdir -p ~/bin

ln -sf ~/projects/dev-workspace/scripts/dws-sessions-init.sh ~/bin/dws-sessions-init.sh
ln -sf ~/projects/dev-workspace/scripts/dws-cron-setup.sh ~/bin/dws-cron-setup.sh
ln -sf ~/projects/dev-workspace/scripts/dws-status.sh ~/bin/dws-status.sh
ln -sf ~/projects/dev-workspace/scripts/dws-doctor.sh ~/bin/dws-doctor.sh
```

When you update the repo later, refresh the files `vm-setup.sh` deployed with:

```bash
~/projects/dev-workspace/scripts/dws-update.sh --force
```

## 8. Optional User `systemd` Services

The repo-managed user units are:

- `dws-sessions-init.service`
- `dws-task-monitor.service`

Their purpose:

- `dws-sessions-init.service` starts the expected tmux sessions at boot
- `dws-task-monitor.service` runs `~/bin/task-monitor.sh`

Prerequisites before you install them:

- `~/bin/dws-sessions-init.sh` exists and is executable
- `~/bin/task-monitor.sh` exists and is executable
- `~/projects/wrkflo-orchestrator` exists
- `codex` works and `~/.config/wrkflo/foundry.env` is present

`~/bin/task-monitor.sh` is not stored in this repo. It is operator-managed
runtime code. If you do not have that script yet, skip this section.

Install and start the units:

```bash
sudo loginctl enable-linger "$USER"
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user start dws-sessions-init.service
systemctl --user start dws-task-monitor.service
```

Verify:

```bash
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
tmux ls
```

Note: `vm-setup.sh` separately installs any user units shipped by the sibling
`wrkflo-orchestrator` repo. Those units are in addition to the two repo-managed
`dws-*` services above.

## 9. Cron

There are two cron paths in this repo.

### 9.1 Base cron installed by `vm-setup.sh`

`vm-setup.sh` installs a simple health-check cron entry:

```cron
*/15 * * * * "$HOME/bin/dws-health-check.sh" >/dev/null 2>&1
```

Verify it with:

```bash
crontab -l
systemctl is-active cron
```

### 9.2 Full managed cron block

`scripts/dws-cron-setup.sh` manages a larger block with:

- health checks every 15 minutes
- weekly log rotation at `30 2 * * 0`
- daily session cleanup at `0 4 * * *`

Install it only after all target scripts exist. The installer requires:

- a health-check script
- a cleanup script
- a log-rotation script

The repo already provides:

- `scripts/dws-health-check.sh`
- `scripts/dws-cleanup.sh`

The repo does not currently ship `scripts/dws-rotate-logs.sh`, so you must
either provide your own executable path in `DWS_LOG_ROTATE_SCRIPT` or skip the
full managed cron block for now.

Example if you have a rotate script at `~/bin/dws-rotate-logs.sh`:

```bash
DWS_LOG_ROTATE_SCRIPT="$HOME/bin/dws-rotate-logs.sh" \
  ~/projects/dev-workspace/bin/dws-cron-setup.sh
```

Useful verification commands:

```bash
~/projects/dev-workspace/bin/dws-cron-setup.sh --show
~/projects/dev-workspace/bin/dws-cron-setup.sh --check
crontab -l
```

## 10. Mac and Tailscale Client Setup

From your Mac checkout of this repo, if you want the Mac on the same mesh and
want the VM to reach back into it:

```bash
./mac-setup/bootstrap.sh
open -a Tailscale
./mac-setup/authorize-vm.sh
```

That enables Remote Login on the Mac, installs Tailscale.app, and authorizes
the VM's SSH public key for VM -> Mac access.

## 11. Termius Setup

On iPhone or desktop Termius:

1. Install Tailscale and join the same tailnet.
2. Import the same private SSH key you use for the VM.
3. Create a host for `dev-workspace-vm`.

You can print the current recommended settings from the VM or Mac with:

```bash
DWS_TERMIUS_HOSTNAME=dev-workspace-vm \
  ~/projects/dev-workspace/bin/dws-termius-setup.sh
```

Use these settings:

- label: `Dev Workspace VM`
- hostname: `dev-workspace-vm`
- port: `22`
- username: `moses`
- authentication: SSH key
- keepalive interval: `30 seconds`
- Mosh: off
- SSH agent forwarding: off
- startup command: blank
- terminal type: `xterm-256color`
- local echo: off

First-connect workflow:

1. Connect to the host in Termius.
2. Let the login shell run normally so `~/bin/dws-launcher.sh` starts.
3. Pick a project and model, or press `r` to reconnect to an existing tmux
   session.
4. Detach with `Ctrl-a d` before closing the app if you want the session to
   keep running.

## 12. Final Validation

Run these checks before you declare the VM ready:

```bash
ssh moses@dev-workspace-vm 'tailscale status >/dev/null && echo tailscale-ok'
ssh moses@dev-workspace-vm 'sudo sshd -t && echo ssh-ok'
ssh moses@dev-workspace-vm '~/bin/dws-health.sh'
ssh moses@dev-workspace-vm '~/projects/dev-workspace/bin/dws-status.sh'
ssh moses@dev-workspace-vm 'crontab -l'
ssh moses@dev-workspace-vm 'tmux ls || echo "no tmux sessions yet"'
```

If you installed the user services, also verify:

```bash
ssh moses@dev-workspace-vm 'systemctl --user list-units --type=service --state=running --no-pager'
```

## 13. Related Docs

- `docs/foundry.md` for Azure Foundry wiring and model mappings
- `docs/tailscale.md` for mesh-specific notes
- `docs/termius-setup.md` for a Termius-only walkthrough
- `docs/troubleshooting.md` for SSH, Tailscale, tmux, and monitor recovery
