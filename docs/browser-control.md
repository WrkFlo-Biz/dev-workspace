# Browser control (VM -> Mac Chrome)

Lets codex on `dev-workspace-vm` drive the dedicated Chrome automation profile
on this Mac over the DevTools Protocol. This is the Chrome-side half of the Mac
control path; the broader `9223` GUI bridge is documented in
`docs/mac-remote-control.md`.

## Current runtime model

```
┌──────────────┐   http://100.78.207.22:9222   ┌────────────────────────────┐
│ VM codex     │ ────────────────────────────► │ com.wrkflo.chrome-cdp-     │
│ puppeteer /  │                               │ relay (launchd + socat)    │
│ playwright   │                               └─────────────┬──────────────┘
└──────────────┘                                             │
                                                             ▼
                                                   127.0.0.1:9222 on Mac
                                                             │
                                                             ▼
                                               Google Chrome automation profile
                                               (`~/chrome-remote-profile`)
```

- Chrome DevTools listens on `127.0.0.1:9222` on the Mac.
- `com.wrkflo.chrome-cdp-relay` keeps the Tailscale-facing relay alive on
  `100.78.207.22:9222`.
- `com.wrkflo.hammerspoon-relay` does the same for the Mac GUI bridge on
  `100.78.207.22:9223`.
- The durable login-time ownership now lives in those dedicated relay
  LaunchAgents, not in the older single-script bridge flow.

## Files

- `mac-setup/chrome-cdp.sh` — launches the dedicated Chrome automation instance
  and waits for local CDP on `127.0.0.1:9222`.
- `mac-setup/chrome-cdp-relay.sh` — exposes `9222` from the Tailscale address
  to local Chrome CDP with `socat`.
- `mac-setup/com.wrkflo.chrome-cdp-relay.plist` — launchd job that keeps the
  `9222` relay alive.
- `mac-setup/hammerspoon-relay.sh` — exposes `9223` from the Tailscale address
  to local Hammerspoon.
- `mac-setup/com.wrkflo.hammerspoon-relay.plist` — launchd job that keeps the
  `9223` relay alive.
- `mac-setup/com.wrkflo.chrome-cdp.plist` — older Chrome bootstrap LaunchAgent.
  Useful as a manual/bootstrap path, but not the preferred long-lived relay
  owner anymore.
- `mac-setup/mac-bridges.sh` / `com.wrkflo.mac-bridges.plist` — older combined
  bridge flow. Keep it as a recovery/bootstrap helper; do not treat it as the
  source of truth for the current split relay design.
- `scripts/control-mac-chrome.js` — Puppeteer example.
- `scripts/control-mac-chrome.sh` — wrapper that resolves global Node deps.

## Expected state on the Mac

The intended steady state is:

- Chrome automation profile running locally with CDP on `127.0.0.1:9222`
- `com.wrkflo.chrome-cdp-relay` loaded under `gui/<uid>`
- `com.wrkflo.hammerspoon-relay` loaded under `gui/<uid>`
- Tailscale listeners reachable on `100.78.207.22:9222` and `:9223`

Useful checks on the Mac:

```bash
launchctl print gui/$(id -u)/com.wrkflo.chrome-cdp-relay
launchctl print gui/$(id -u)/com.wrkflo.hammerspoon-relay
curl -fsS http://127.0.0.1:9222/json/version
curl -fsS http://100.78.207.22:9222/json/version
```

## Usage from the VM

```bash
# sanity check
curl -fsS http://100.78.207.22:9222/json/version

# run the example
~/projects/dev-workspace/scripts/control-mac-chrome.sh
```

### Puppeteer

```js
const puppeteer = require('puppeteer-core');
const browser = await puppeteer.connect({
  browserURL: 'http://100.78.207.22:9222',
});
```

### Playwright

```js
const { chromium } = require('playwright-core');
const browser = await chromium.connectOverCDP('http://100.78.207.22:9222');
```

## Recovery / fallback

If the durable relay jobs are missing or you are rebuilding the Mac side from
scratch:

1. Run `mac-setup/chrome-cdp.sh` to bring Chrome CDP up locally.
2. Load or restart `com.wrkflo.chrome-cdp-relay.plist`.
3. Load or restart `com.wrkflo.hammerspoon-relay.plist` if you also need GUI
   automation on `9223`.

Use `mac-bridges.sh` only as a broader bootstrap/recovery helper when you want
the older combined flow in one command.

## Troubleshooting

- `ECONNREFUSED 100.78.207.22:9222` — the relay job is down or Chrome CDP is
  not listening locally. Check the two `launchctl print ...relay` commands
  above, then verify `curl http://127.0.0.1:9222/json/version` on the Mac.
- `ECONNREFUSED 127.0.0.1:9222` on the Mac — Chrome is not running with the
  automation profile. Re-run `mac-setup/chrome-cdp.sh`.
- Tabs from your regular Chrome do not appear — intentional. Automation uses
  `~/chrome-remote-profile`, separate from your daily browser profile.
- GUI actions work but browser control does not — `9223` and `9222` are split
  on purpose now; check the Chrome relay specifically instead of assuming the
  Hammerspoon side implies CDP is healthy.

## Security

CDP has no built-in authentication. Anything that can hit
`100.78.207.22:9222` can control that Chrome automation profile. Keep access
inside your Tailscale tailnet and tighten ACLs if other devices or users are
present.
