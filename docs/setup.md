# From-Scratch Setup Guide

This guide takes a fresh Ubuntu Azure VM to a working `dev-workspace` install
for a new operator. It covers the current expected setup path for:

- Azure VM provisioning
- repo checkout under `~/projects/dev-workspace`
- Azure Foundry credentials
- Tailscale join and MagicDNS access
- current SSH hardening at `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf`
- repo script layout and `~/bin` deployment convention
- repo-managed user `systemd` services
- cron, Mac-side access, and Termius setup

The current expected VM user is `moses` and the current hostname is
`dev-workspace-vm`. Adjust usernames, resource groups, and hostnames if you are
intentionally building a different environment.

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

## 3. Clone the Repo and Run the Bootstrap

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
- enables `tailscaled` and `cron`
- generates an SSH key if the VM does not already have one
- writes the current SSH hardening drop-in at
  `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf`
- clones the sibling Wrk-Flo repos into `~/projects`
- copies `config/tmux.conf` to `~/.tmux.conf`
- copies `dws-launcher.sh`, `dws-health.sh`, `dws-health-check.sh`,
  `dws-rotate-logs.sh`, and `dws-notify.sh` into `~/bin`
- updates `~/.bash_profile` so interactive SSH logins source the launcher
- creates the base 15-minute health-check cron entry
- installs any `wrkflo-orchestrator` user units found under
  `~/projects/wrkflo-orchestrator/ops/systemd`

What `vm-setup.sh` does **not** finish for you:

- it does not run `tailscale up`, so the VM is not joined to the tailnet yet
- it does not authenticate `gh` or `az` for you
- it does not install the repo-managed `dws-sessions-init.service` and
  `dws-task-monitor.service`
- it does not provide `~/bin/task-monitor.sh` because that script is
  operator-managed and not stored in this repo

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
test -f ~/.config/wrkflo/foundry.env && echo "foundry env ok"
```

## 5. Bring Up Tailscale

Install and base enablement happen in `vm-setup.sh`; the remaining step is
joining the tailnet:

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up --ssh --operator="$USER" --hostname=dev-workspace-vm
```

Approve the auth URL that command prints, then verify:

```bash
systemctl is-enabled tailscaled
systemctl is-active tailscaled
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

If MagicDNS is missing on a client later, run `tailscale up --accept-dns=true`
on that client.

## 6. Verify the Current SSH Hardening File

On a fresh build, `vm-setup.sh` should already install the current SSH
hardening file to:

```text
/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
```

The repo source of truth is:

```text
~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf
```

The expected effective values are:

- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- `ChallengeResponseAuthentication no`
- `PubkeyAuthentication yes`
- `PermitRootLogin no`
- `X11Forwarding no`
- `MaxAuthTries 3`
- `ClientAliveInterval 30`
- `ClientAliveCountMax 3`

If the live host is missing the file or you detect drift, reinstall it from the
repo copy:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo install -m 0644 \
  ~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf \
  /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo rm -f /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

Before you close the original public-IP session:

1. Confirm `sudo sshd -t` succeeds.
2. Open a second session over Tailscale or the public IP.
3. Only close the original shell after the second login succeeds.

Verify the installed settings:

```bash
grep -E 'PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|PermitRootLogin|X11Forwarding|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax' \
  /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|permitrootlogin|maxauthtries|x11forwarding|clientaliveinterval|clientalivecountmax) '
sudo systemctl status ssh --no-pager || sudo systemctl status sshd --no-pager
```

Optional but recommended after Tailscale is proven: inspect the firewall path
before applying any host-level restrictions:

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --dry-run
```

## 7. Understand the Script Layout

The repo script convention is:

- `scripts/` is the canonical source for repo shell entrypoints
- most files in `bin/` are thin repo-local wrappers that `exec` into
  `scripts/`
- `bin/dws-systemd-user-setup.sh` and `bin/dws-boot-verify.sh` are
  repo-owned standalone entrypoints rather than wrappers
- `~/bin/` on the VM is the live runtime path for login hooks, cron targets,
  `systemd` entrypoints, and operator-managed helpers

Important rule: do **not** symlink the thin-wrapper subset from repo `bin/`
into `~/bin`. Those wrappers resolve `../scripts` relative to their invocation
path and can break when called through a `~/bin` symlink. For `~/bin`, either
install a real copy or symlink directly to `~/projects/dev-workspace/scripts/...`.

`vm-setup.sh` already copies these into `~/bin`:

- `dws-launcher.sh`
- `dws-health.sh`
- `dws-health-check.sh`
- `dws-rotate-logs.sh`
- `dws-notify.sh`

Install the additional live symlinks you want for day-2 operations:

```bash
mkdir -p ~/bin

ln -sf ~/projects/dev-workspace/scripts/dws-sessions-init.sh ~/bin/dws-sessions-init.sh
ln -sf ~/projects/dev-workspace/scripts/dws-sessions.sh ~/bin/dws-sessions.sh
ln -sf ~/projects/dev-workspace/scripts/dws-status.sh ~/bin/dws-status.sh
ln -sf ~/projects/dev-workspace/scripts/dws-doctor.sh ~/bin/dws-doctor.sh
ln -sf ~/projects/dev-workspace/scripts/dws-cron-setup.sh ~/bin/dws-cron-setup.sh
ln -sf ~/projects/dev-workspace/scripts/dws-log-viewer.sh ~/bin/dws-log-viewer.sh
ln -sf ~/projects/dev-workspace/scripts/dws-backup.sh ~/bin/dws-backup.sh
ln -sf ~/projects/dev-workspace/scripts/dws-tailscale-diag.sh ~/bin/dws-tailscale-diag.sh
ln -sf ~/projects/dev-workspace/scripts/dws-termius-setup.sh ~/bin/dws-termius-setup.sh
```

`scripts/dws-update.sh` currently refreshes `~/.tmux.conf`,
`~/bin/dws-health.sh`, `~/bin/dws-health-check.sh`,
`~/bin/dws-rotate-logs.sh`, and `~/bin/dws-notify.sh`. It does **not**
currently refresh `~/bin/dws-launcher.sh`, so reinstall that file manually or
rerun `vm-setup.sh` after launcher changes. For the symlinked helpers above,
repo updates are picked up automatically because the symlink already points at
`scripts/...`.

## 8. Install and Verify Services

After bootstrap and `tailscale up`, the expected long-lived services are:

- system: `ssh` or `sshd`, `tailscaled`, and `cron`
- user: `dws-sessions-init.service` and, when you have the operator script,
  `dws-task-monitor.service`
- additional user units from `~/projects/wrkflo-orchestrator/ops/systemd`
  if that repo ships them

Verify the base system services first:

```bash
systemctl is-enabled tailscaled cron
systemctl is-active tailscaled cron
systemctl is-enabled ssh 2>/dev/null || systemctl is-enabled sshd
systemctl is-active ssh 2>/dev/null || systemctl is-active sshd
```

Then install the repo-managed user services.

The repo-managed user units are:

- `dws-sessions-init.service`
- `dws-task-monitor.service`

Tracked templates live in `config/systemd-user/`, and the installer is:

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh
```

Their purpose:

- `dws-sessions-init.service` recreates the managed `tmux` pool at boot
- `dws-task-monitor.service` runs `~/bin/task-monitor.sh`

Prerequisites before you install them:

- `~/bin/dws-sessions-init.sh` exists and is executable
- `~/bin/task-monitor.sh` exists and is executable
- `codex` works
- `~/.config/wrkflo/foundry.env` exists
- `~/projects/wrkflo-orchestrator` exists

`~/bin/task-monitor.sh` is not stored in this repo. It is operator-managed
runtime code. If you do not have that script yet, skip `dws-task-monitor.service`
until you do.

Install and enable linger so the services survive reboot without an active
login:

```bash
sudo loginctl enable-linger "$USER"
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user start dws-sessions-init.service
systemctl --user start dws-task-monitor.service
```

Verify the user-service install:

```bash
loginctl show-user "$USER" -p Linger
systemctl --user is-enabled dws-sessions-init.service dws-task-monitor.service
systemctl --user show dws-sessions-init.service -p ExecStart -p FragmentPath -p UnitFileState
systemctl --user show dws-task-monitor.service -p ExecStart -p FragmentPath -p UnitFileState
ls -l ~/.config/systemd/user/default.target.wants/dws-sessions-init.service \
      ~/.config/systemd/user/default.target.wants/dws-task-monitor.service
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
tmux ls
```

Expected `ExecStart` after specifier expansion for the `moses` account:

- `/usr/bin/bash /home/moses/bin/dws-sessions-init.sh`
- `/usr/bin/bash /home/moses/bin/task-monitor.sh`

If you intentionally use a different username, the home-directory portion of
those paths will change accordingly.

Note: `vm-setup.sh` separately installs any user units shipped by the sibling
`wrkflo-orchestrator` repo. Those units are in addition to the two repo-managed
`dws-*` services above.

## 9. Cron

There are two cron paths in this repo.

### 9.1 Base cron installed by `vm-setup.sh`

`vm-setup.sh` installs a simple health-check cron entry:

```cron
*/15 * * * * "$HOME/bin/dws-health-check.sh" >>"/var/log/dws/health-check.log" 2>&1
```

Verify it with:

```bash
crontab -l
systemctl is-enabled cron
systemctl is-active cron
```

### 9.2 Full managed cron block

`scripts/dws-cron-setup.sh` manages a larger block with:

- health checks every 15 minutes
- weekly log rotation at `30 2 * * 0`
- daily session cleanup at `0 4 * * *`

The repo now provides all of the required targets:

- `scripts/dws-health-check.sh`
- `scripts/dws-cleanup.sh`
- `scripts/dws-rotate-logs.sh`

Install the managed block once those scripts are present:

```bash
~/projects/dev-workspace/bin/dws-cron-setup.sh
```

Useful verification commands:

```bash
~/projects/dev-workspace/bin/dws-cron-setup.sh --show
~/projects/dev-workspace/bin/dws-cron-setup.sh --check
crontab -l
```

By default the managed cron block writes its logs under `/var/log/dws`.

## 10. Mac and Tailnet Client Setup

From your Mac checkout of this repo, if you want the Mac on the same mesh and
want the VM to reach back into it:

```bash
~/projects/dev-workspace/mac-setup/bootstrap.sh
open -a Tailscale
~/projects/dev-workspace/mac-setup/authorize-vm.sh
```

That enables Remote Login on the Mac, installs Tailscale.app, and authorizes
the VM's SSH public key for VM-to-Mac access.

## 11. Termius Setup

On iPhone or desktop Termius:

1. Install Tailscale and join the same tailnet.
2. Import the same private SSH key you use for the VM.
3. Create a host for `dev-workspace-vm`.

You can print the current recommended settings from the VM or Mac with:

```bash
~/projects/dev-workspace/bin/dws-termius-setup.sh
DWS_TERMIUS_HOSTNAME=dev-workspace-vm ~/projects/dev-workspace/bin/dws-termius-setup.sh
```

Use these settings:

- label: `Dev Workspace VM`
- hostname: `dev-workspace-vm` or the Tailscale IP
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
3. Pick a project and model, or press `r` to reconnect to an existing `tmux`
   session.
4. Detach with `Ctrl-a d` before closing the app if you want the session to
   keep running.

## 12. Final Validation

Run these checks before you declare the VM ready:

```bash
ssh moses@dev-workspace-vm 'systemctl is-active tailscaled && tailscale status >/dev/null && tailscale ip -4'
ssh moses@dev-workspace-vm 'systemctl is-active cron && (systemctl is-active ssh || systemctl is-active sshd)'
ssh moses@dev-workspace-vm 'sudo sshd -t && grep -E "PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|PermitRootLogin|X11Forwarding|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax" /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf'
ssh moses@dev-workspace-vm '~/projects/dev-workspace/scripts/dws-health.sh --json | jq ".services, .security, .tailnet"'
ssh moses@dev-workspace-vm '~/projects/dev-workspace/bin/dws-status.sh'
ssh moses@dev-workspace-vm 'crontab -l'
ssh moses@dev-workspace-vm 'tmux ls || echo "no tmux sessions yet"'
```

If you installed the repo-managed user services, also verify:

```bash
ssh moses@dev-workspace-vm '
  loginctl show-user moses -p Linger &&
  systemctl --user is-enabled dws-sessions-init.service dws-task-monitor.service &&
  systemctl --user show dws-sessions-init.service -p ExecStart -p FragmentPath -p UnitFileState &&
  systemctl --user show dws-task-monitor.service -p ExecStart -p FragmentPath -p UnitFileState &&
  systemctl --user status dws-sessions-init.service --no-pager &&
  systemctl --user status dws-task-monitor.service --no-pager
'
```

## 13. Related Docs

- `docs/foundry.md` for Azure Foundry wiring and model mappings
- `docs/tailscale.md` for mesh-specific notes
- `docs/script-layout.md` for the script layout convention
- `docs/termius-setup.md` for a Termius-only walkthrough
- `docs/troubleshooting.md` for SSH, Tailscale, tmux, and monitor recovery
- `docs/runbook.md` for operator procedures after setup
