# dev-workspace architecture

This document describes the live `dev-workspace` system as of April 23, 2026:
the Azure VM, the Tailscale mesh, the SSH and `tmux` session model, the active
task monitor, and the Mac-side relay setup that lets the VM drive the Mac.

## System summary

The core path is:

```text
Mac Terminal.app / iPhone Termius
        -> Tailscale / MagicDNS
        -> dev-workspace-vm
        -> SSH login shell
        -> ~/bin/dws-launcher.sh
           (deployed from scripts/dws-launcher.sh)
        -> tmux
        -> codex --profile ... / claude
```

The VM is also a control point for the Mac:

```text
dev-workspace-vm
  -> ssh mosestut@100.78.207.22
  -> http://100.78.207.22:9222  (Chrome CDP)
  -> http://100.78.207.22:9223  (Hammerspoon GUI API)
```

`tmux` is the persistence boundary. SSH can drop, the phone can sleep, and the
Codex or Claude process keeps running inside the VM session.

## VM and infrastructure

Source of truth: [`infra/dev-workspace-vm.bicep`](../infra/dev-workspace-vm.bicep)

Current VM shape:

| Item | Value |
| --- | --- |
| Azure VM name | `dev-workspace-vm` |
| Region | `westus2` |
| VM size | `Standard_D2s_v5` |
| CPU / RAM | `2 vCPU / 8 GB` |
| OS image | `Canonical ubuntu-24_04-lts server` |
| OS disk | `Premium_LRS` |
| VNet | `10.0.0.0/16` |
| Subnet | `10.0.0.0/24` |
| VM private IP | `10.0.0.4` |
| Public fallback IP | `20.230.203.79` |
| Public inbound rule | TCP `22` open in the NSG |

Operational notes:

- Tailscale is the primary access path.
- The public IP is fallback-only for SSH when Tailscale or MagicDNS is down.
- Azure Foundry env is loaded from `~/.config/wrkflo/foundry.env`.

## Tailscale mesh

Current tailnet identity data from `tailscale status` on the VM:

| Node | Role | MagicDNS | IPv4 |
| --- | --- | --- | --- |
| `dev-workspace-vm` | primary Azure dev VM | `dev-workspace-vm.tail18ff5a.ts.net` | `100.117.16.63` |
| `Moses’s MacBook Air (3)` | operator Mac | `mosess-macbook-air-3.tail18ff5a.ts.net` | `100.78.207.22` |
| `iphone-15-pro-max` | iPhone running Termius + Tailscale | `iphone-15-pro-max.tail18ff5a.ts.net` | `100.88.249.22` |
| `openclaw-gateway-vm` | sibling tailnet gateway peer used by connectivity checks | `openclaw-gateway-vm.tail18ff5a.ts.net` | `100.126.194.98` |

Topology:

```text
                           Tailscale tailnet

   iPhone / Termius                         Mac / Terminal.app
   100.88.249.22                            100.78.207.22
   iphone-15-pro-max                        mosess-macbook-air-3
          \                                       /
           \                                     /
            \                                   /
             +-------- dev-workspace-vm -------+
                      100.117.16.63
                      dev-workspace-vm
                      Azure VM in westus2
                              |
                              +-- public SSH fallback: 20.230.203.79

   sibling tailnet peer: openclaw-gateway-vm 100.126.194.98
```

Notes:

- The Mac and phone should normally use MagicDNS hostnames first.
- `bin/dws-connect-test.sh` treats the Mac, iPhone, and `openclaw-gateway-vm`
  as the three named peer checks.
- Direct vs DERP-relayed transport can change by network; only the `100.x.y.z`
  addresses should be treated as stable.

## SSH and login lifecycle

Interactive SSH logins land in the installed launcher unless
`SKIP_LAUNCHER=1` is set:

```text
ssh moses@dev-workspace-vm
  -> login shell / bash -l
  -> loads ~/.config/wrkflo/foundry.env if needed
  -> ~/bin/dws-launcher.sh
  -> project picker or reconnect menu
  -> tmux attach/new-session
  -> codex or claude inside ~/projects/<repo>
```

Live behavior is deployed from [`scripts/dws-launcher.sh`](../scripts/dws-launcher.sh):

- Runs only for interactive shells.
- Shows active session count, health timestamp, disk usage, and queue summary.
- Lets the operator reconnect with `r`, kill sessions, or clean old sessions.
- Creates session names in the form `<project-short>-<profile-label>`, for
  example `dws-5-4`, `orch-codex`, or `gs-claude`.
- Wraps the model command in a restart loop so a crash or compaction leaves the
  `tmux` session alive and prompts for `[r]estart / [q]uit:`.

The Mac desktop shortcut is the operator fast path:

- [`mac-setup/dev-workspace.command`](../mac-setup/dev-workspace.command)
  tries `dev-workspace-vm` first.
- If the hostname does not answer, it falls back to `20.230.203.79`.
- It runs `ssh -t "moses@$HOST" "bash -l"` so the launcher opens normally.

## tmux layout and session model

Source of truth: [`config/tmux.conf`](../config/tmux.conf)

Key settings:

- Prefix is `Ctrl-a`, not `Ctrl-b`.
- Mouse mode is on by default.
- Base index is `1` for windows and panes.
- `Ctrl-a H` opens the health popup.
- `Ctrl-a m` toggles mouse mode for easier copy/paste in Termius.

There are two categories of sessions.

### User sessions

User sessions are created by the launcher or `scripts/dws-quick.sh` and are
named by repo short name plus profile label:

| Repo short | Example session names |
| --- | --- |
| `gs` | `gs-5-4`, `gs-sonnet`, `gs-claude` |
| `voice` | `voice-codex`, `voice-mini` |
| `oclaw` | `oclaw-5mini` |
| `gsaq` | `gsaq-opus` |
| `orch` | `orch-5-4`, `orch-claude` |
| `dws` | `dws-5-4`, `dws-codex`, `dws-claude` |

Session metadata is persisted in two places:

- `tmux` session options: `@dws_project`, `@dws_model`, `@dws_profile`, `@dws_task`
- `~/.local/state/dev-workspace/session-meta/<session>.tsv`

Recovery and inspection are handled by
[`bin/dws-sessions.sh`](../bin/dws-sessions.sh):

- `list` shows session state and last known task
- `show` shows crash markers, path, profile, relaunch hints
- `reconnect` attaches to the newest or named session
- `recover` respawns the original pane command in place
- `relaunch` starts a fresh quick-launch session for the same repo/profile

### Managed tmux sessions

The service-managed `tmux` pool expected on the VM is:

```text
dws-a
dws-b
orchestrator
worker-c
worker-d
worker-e
worker-f
worker-g
worker-h
```

Operational meaning:

- `orchestrator` is a dedicated `wrkflo-orchestrator` Codex session.
- `dws-a`, `dws-b`, and `worker-c` through `worker-h` are autonomous worker panes.
- The monitor is not part of the managed `tmux` pool anymore; it runs as the
  user service `dws-task-monitor.service`.
- Additional ad hoc sessions can exist during live operation. Those sessions are
  not part of the managed boot set and should not be used as the expected
  service baseline.

This matters because older docs reference a `planner` tmux session. On this VM,
the active control-plane session observed on April 23, 2026 is `orchestrator`,
not `planner`.

### Systemd user services

Service installation is defined by:

- [`config/systemd-user/dws-sessions-init.service`](../config/systemd-user/dws-sessions-init.service)
- [`config/systemd-user/dws-task-monitor.service`](../config/systemd-user/dws-task-monitor.service)
- [`bin/dws-systemd-user-setup.sh`](../bin/dws-systemd-user-setup.sh)

Managed units:

| Unit | ExecStart | Role |
| --- | --- | --- |
| `dws-sessions-init.service` | `/usr/bin/bash %h/bin/dws-sessions-init.sh` | oneshot bootstrap that recreates the 9 managed `tmux` sessions |
| `dws-task-monitor.service` | `/usr/bin/bash %h/bin/task-monitor.sh` | long-running monitor loop that starts after `dws-sessions-init.service` |

The installed `~/bin` copies are the live service entrypoints. The repo files
are the source used to install or redeploy them.

## Task monitor

Current live entrypoint: `~/bin/task-monitor.sh`

Current service: `dws-task-monitor.service`

Current runtime characteristics:

| Item | Value |
| --- | --- |
| Loop interval | `30` seconds |
| Queue file | `~/projects/dev-workspace/.state/task-queue.json` |
| Monitor log | `/var/log/dws/monitor.log` |
| Managed workers | `dws-a`, `dws-b`, `worker-c`..`worker-h` |
| Special session | `orchestrator` is health-checked and recreated immediately if missing |

Behavior:

- Reads the tail of each worker pane and classifies it as `WORKING`, `IDLE`,
  `COMPACTED`, `CRASHED`, `RATELIMIT`, `DEAD`, or `UNKNOWN`.
- Marks `in_progress` tasks complete when a worker goes idle again.
- Assigns the next pending task from
  `~/projects/dev-workspace/.state/task-queue.json`.
- Auto-refills the queue when pending tasks drop below the low-water mark.
- Relaunches crashed, compacted, or dead workers in fresh `tmux` sessions.
- Recreates the `orchestrator` session immediately if it crashes or disappears.
- Writes the operator-visible cycle log to `/var/log/dws/monitor.log`.

Some repo tooling still defaults to legacy `/tmp/monitor-*` or `/tmp/task-queue`
artifacts. Treat the user-service state, the managed queue under `.state/`, and
`/var/log/dws/monitor.log` as the authoritative runtime surfaces.

The quickest runtime truth checks are:

```bash
systemctl --user status dws-sessions-init.service --no-pager
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
sed -n '1,220p' ~/projects/dev-workspace/.state/task-queue.json
tmux list-sessions
```

`bin/dws-status.sh` and `scripts/dws-launcher.sh status` summarize the same
environment and also try to read the local orchestrator health API at
`http://127.0.0.1:8100/v1/workspace/health` when it is available.

## Foundry model layer

The launcher routes Codex traffic into one Azure AI Foundry resource instead of
using direct OpenAI public endpoints.

| Item | Value |
| --- | --- |
| Foundry resource | `moses-8586-resource` |
| Resource group | `rg-moses-8586` |
| Region | `eastus2` |
| Endpoint | `https://moses-8586-resource.cognitiveservices.azure.com` |

Profile source of truth:

- [`config/codex-profiles/`](../config/codex-profiles)
  contains the provider fragment plus the launcher profiles.
- [`scripts/apply-codex-profiles.sh`](../scripts/apply-codex-profiles.sh)
  merges them into `~/.codex/config.toml`.
- [`scripts/dws-env.sh`](../scripts/dws-env.sh)
  maps launcher choices to the correct profile labels.

Launcher-exposed profiles:

- `foundry-5_4` -> `gpt-5.4`
- `foundry-5_2` -> `gpt-5.2`
- `foundry-codex` -> `gpt-5.2-codex`
- `foundry-mini` -> `gpt-5.1-codex-mini`
- `foundry-5-mini` -> `gpt-5-mini`
- `foundry-4o` -> `gpt-4o`
- `foundry-opus` -> `claude-opus-4-6`
- `foundry-sonnet` -> `claude-sonnet-4-6`
- `foundry-haiku` -> `claude-haiku-4-5`

Credential flow:

- `AZURE_OPENAI_API_KEY` is loaded from `~/.config/wrkflo/foundry.env`.
- Interactive SSH, the launcher, and the monitor/orchestrator runtime all rely
  on that file being present.
- If it is missing, the launcher and status tooling surface the failure quickly.

## Mac-side relay and reconnect behavior

### VM to Mac paths

The VM talks to the Mac over Tailscale using three different mechanisms:

| Path | Endpoint | Purpose |
| --- | --- | --- |
| SSH | `mosestut@100.78.207.22` | shell access, rsync, repo sync |
| Chrome CDP | `http://100.78.207.22:9222` | browser automation via Puppeteer / Playwright |
| Hammerspoon | `http://100.78.207.22:9223` | GUI automation, AppleScript, keystrokes, screenshots |

The shared env defaults live in [`scripts/dws-env.sh`](../scripts/dws-env.sh):

- `MAC_SSH_HOST=mosestut@100.78.207.22`
- `MAC_CDP_URL=http://100.78.207.22:9222`
- `MAC_GUI_URL=http://100.78.207.22:9223`

### LaunchAgents on the Mac

Installed by [`mac-setup/mac-setup.sh`](../mac-setup/mac-setup.sh):

| LaunchAgent | Purpose | Important behavior |
| --- | --- | --- |
| `com.wrkflo.chrome-cdp` | starts Chrome with remote debugging | `RunAtLoad`, `KeepAlive` on abnormal exit |
| `com.wrkflo.mac-bridges` | reruns the full bridge startup script | `RunAtLoad`, `StartInterval=60` |

Bridge ownership:

- [`mac-setup/chrome-cdp.sh`](../mac-setup/chrome-cdp.sh)
  starts Chrome on `127.0.0.1:9222` with a dedicated profile at
  `~/chrome-remote-profile`.
- [`mac-setup/mac-bridges.sh`](../mac-setup/mac-bridges.sh)
  rechecks localhost services and re-bridges them onto the current Tailscale IP
  with `socat`.

### "Mac reconnect agent" clarification

There is no separate `autossh` or reverse-SSH daemon in this repo.

The reconnect model is:

- Interactive Mac -> VM reconnect is manual but fast via
  `~/Desktop/Dev Workspace.command` or `ssh moses@dev-workspace-vm`.
- Once connected, the launcher's `r` path reattaches to the right `tmux` session.
- Background resiliency on the Mac comes from the two LaunchAgents above, which
  keep `9222` and `9223` available after login and rerun the bridge setup every
  minute.

If the Mac sleeps, the tailnet path disappears. Keep it awake with the usual
macOS sleep settings or `caffeinate -dimsu &`.

## SSH keepalive

### Current server-side behavior on the VM

Observed from `/etc/ssh/sshd_config.d`:

- `ClientAliveInterval 120` in `50-cloudimg-settings.conf`
- `PasswordAuthentication yes`
- `PubkeyAuthentication yes`
- `PermitRootLogin no`

There is no repo-managed `~/.ssh/config` snippet yet, so client keepalive is
set at the terminal app level today rather than by a checked-in host config.

### Termius settings

Source: [`bin/dws-termius-setup.sh`](../bin/dws-termius-setup.sh)
and [`docs/termius-setup.md`](./termius-setup.md)

Recommended settings:

- Hostname: `dev-workspace-vm` or `100.117.16.63`
- Port: `22`
- Username: `moses`
- Authentication: SSH key
- Keepalive interval: `30` seconds
- Mosh: off
- SSH agent forwarding: off
- Startup command: blank
- Terminal type: `xterm-256color`
- Local echo: off

### Recommended Terminal.app config

Suggested `~/.ssh/config` stanza on the Mac:

```sshconfig
Host dev-workspace-vm
  HostName dev-workspace-vm
  User moses
  ServerAliveInterval 30
  ServerAliveCountMax 5
  TCPKeepAlive yes

Host dev-workspace-vm-public
  HostName 20.230.203.79
  User moses
  ServerAliveInterval 30
  ServerAliveCountMax 5
  TCPKeepAlive yes
```

Then use either:

```bash
ssh moses@dev-workspace-vm
ssh dev-workspace-vm
ssh dev-workspace-vm-public
```

## How to connect

### From Mac Terminal.app

1. Make sure the Mac is signed into the same Tailscale tailnet.
2. Preferred path: `ssh moses@dev-workspace-vm`
3. Direct Tailscale IP path: `ssh moses@100.117.16.63`
4. Fallback public path: `ssh moses@20.230.203.79`
5. After login, let the launcher open and either:
   - press `r` to reconnect to the last `tmux` session
   - choose a repo and model to create a new one
6. Detach with `Ctrl-a d` when you want the job to survive disconnect.

Fastest Mac operator path:

```bash
open ~/Desktop/Dev\ Workspace.command
```

### From desktop or iPhone Termius

1. Run
   [`bin/dws-termius-setup.sh`](../bin/dws-termius-setup.sh)
   on a machine that already has the SSH key.
2. Import the same private key into Termius.
3. Create a VM host with:
   - hostname `dev-workspace-vm` or `100.117.16.63`
   - port `22`
   - username `moses`
   - keepalive `30s`
4. Leave the startup command blank so the launcher still runs.
5. On iPhone, use landscape mode when working in Codex or Claude.
6. Reconnect later with the launcher `r` key or
   `~/projects/dev-workspace/bin/dws-sessions.sh reconnect`.

Optional phone -> Mac host:

- hostname `mosess-macbook-air-3` or `100.78.207.22`
- username `mosestut`
- same SSH key after `mac-setup/authorize-vm.sh` has added it to the Mac

### From the VM back into the Mac

```bash
ssh mosestut@100.78.207.22
curl http://100.78.207.22:9222/json/version
curl -X POST http://100.78.207.22:9223/apps -H 'Content-Type: application/json' -d '{}'
```

## Troubleshooting

### SSH drops or phone sleep disconnects

Recovery:

1. Reconnect to `dev-workspace-vm`
2. Press `r` in the launcher
3. If needed:

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
```

If drops are frequent, make sure the client keepalive is `30s` and prefer the
Tailscale hostname over the public IP.

### MagicDNS or Tailscale path is down

Checks:

```bash
tailscale status
tailscale ping 100.78.207.22
tailscale ping 100.88.249.22
~/projects/dev-workspace/bin/dws-connect-test.sh
```

Fallback:

- Try `ssh moses@100.117.16.63`
- Then `ssh moses@20.230.203.79`

### Launcher does not appear

Likely causes:

- non-interactive SSH
- `SKIP_LAUNCHER=1` is set
- you are already inside `tmux`

Recovery:

```bash
unset SKIP_LAUNCHER
~/bin/dws-launcher.sh
```

### Session is missing, compacted, or back at a shell prompt

Use the session tool instead of guessing:

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh recover <session>
~/projects/dev-workspace/bin/dws-sessions.sh relaunch <session>
```

### Monitor looks stale

Checks:

```bash
systemctl --user status dws-task-monitor.service --no-pager
journalctl --user -u dws-task-monitor.service -n 40 --no-pager
tmux list-sessions
tail -n 40 /var/log/dws/monitor.log
sed -n '1,220p' ~/projects/dev-workspace/.state/task-queue.json
```

Restart:

```bash
systemctl --user restart dws-task-monitor.service
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```

The monitor will recreate the `orchestrator` session on its next cycle if that
session is missing.

### Mac control ports `9222` or `9223` are down

Checks on the Mac:

```bash
launchctl list | grep wrkflo
tail -n 40 /tmp/mac-bridges.out.log
tail -n 40 /tmp/socat-9222.log
tail -n 40 /tmp/socat-9223.log
```

Recovery on the Mac:

```bash
bash ~/dev-workspace/mac-setup/mac-bridges.sh
```

If `9223` still fails, verify Hammerspoon has Accessibility, Screen Recording,
and Automation permissions.

### VM -> Mac SSH fails

Checks:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 mosestut@100.78.207.22 'printf ok'
```

If this fails:

- make sure the Mac is awake and online in Tailscale
- rerun
  [`mac-setup/authorize-vm.sh`](../mac-setup/authorize-vm.sh)
- confirm the key exists in the Mac's `~/.ssh/authorized_keys`

## Related docs

- [`docs/runbook.md`](./runbook.md)
- [`docs/troubleshooting.md`](./troubleshooting.md)
- [`docs/tailscale.md`](./tailscale.md)
- [`docs/termius-setup.md`](./termius-setup.md)
- [`docs/mac-remote-control.md`](./mac-remote-control.md)
- [`docs/phone-control.md`](./phone-control.md)
- [`docs/browser-control.md`](./browser-control.md)
