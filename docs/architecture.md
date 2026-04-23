# dev-workspace architecture

## Network topology

```text
                   Tailscale mesh (primary)

  iPhone / Termius                     Mac / Terminal.app
  100.88.249.22                        100.78.207.22
         \                                   /
          \                                 /
           \                               /
            +---- dev-workspace-vm -------+
                  100.117.16.63
                  Azure VM (westus2)

  Public SSH fallback for VM only: 20.230.203.79
```

- Primary path is Tailscale: phone and Mac both reach the VM over the tailnet.
- Public IP is only a fallback path when MagicDNS or Tailscale is unavailable.

## Login and session path

```text
SSH -> login shell / ~/.bash_profile -> scripts/dws-launcher.sh
    -> tmux session (new or reconnect)
    -> codex --profile <foundry-profile> | claude
```

- Interactive SSH logins land in the launcher automatically.
- The launcher picks project + model, then reattaches to tmux or creates a new session.
- tmux is the persistence boundary; disconnecting the phone does not kill the agent session.

## Mac bridge path

```text
VM agent/tool -> http://100.78.207.22:9222 -> socat -> 127.0.0.1:9222 -> Chrome CDP
VM agent/tool -> http://100.78.207.22:9223 -> socat -> 127.0.0.1:9223 -> Hammerspoon HTTP
```

- Port `9222` is browser automation against the Mac's dedicated Chrome automation profile.
- Port `9223` is GUI/OS control through Hammerspoon's local HTTP API.
- `mac-setup/chrome-cdp.sh` and `mac-setup/mac-bridges.sh` own relay startup on the Mac.

## Foundry model layer

- Resource: `moses-8586-resource` in `eastus2`.
- Deployments (12): `gpt-5.4`, `gpt-5.2`, `gpt-5.2-codex`, `gpt-5.1-codex-mini`, `gpt-5-mini`, `gpt-4o`, `gpt-realtime`, `gpt-realtime-mini`, `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`, `text-embedding-3-small`.
- Codex launcher profiles (9): `foundry-5_4`, `foundry-5_2`, `foundry-codex`, `foundry-mini`, `foundry-5-mini`, `foundry-4o`, `foundry-opus`, `foundry-sonnet`, `foundry-haiku`.
- Profile definitions live in `config/codex-profiles/`; launcher mappings live in `scripts/dws-env.sh`.

## Phone user data flow

1. User taps `dev-workspace-vm` in Termius on the phone.
2. Termius opens SSH to `moses@dev-workspace-vm` over Tailscale, or `20.230.203.79` as fallback.
3. The VM login shell loads Foundry env and starts `scripts/dws-launcher.sh`.
4. The launcher shows active tmux sessions plus the project/model picker.
5. User reconnects with `r` or creates a new session for a target repo and model.
6. tmux runs `codex` or `claude` inside `~/projects/<repo>` and keeps it alive across disconnects.

## Mac LaunchAgents

- `chrome-cdp-relay` (`com.wrkflo.chrome-cdp`): starts Chrome CDP relay on port `9222`.
- `hammerspoon-relay`: exposes the Hammerspoon HTTP bridge on port `9223`.
- `mac-bridges` (`com.wrkflo.mac-bridges`): login-time supervisor that ensures the Mac-side bridges are up.
- `global-sentinel-sync`: Mac-side sync job for Global Sentinel handoff/state movement when enabled in ops.
