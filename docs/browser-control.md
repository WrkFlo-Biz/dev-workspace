# Browser control (VM → Mac Chrome)

Lets codex on `dev-workspace-vm` drive the Chrome instance on this Mac via
the DevTools Protocol — navigate, read DOM, fill forms, screenshot, run JS.

## Wiring

```
┌──────────────┐   ws://100.78.207.22:9222    ┌─────────────────────────┐
│ VM codex     │ ───────────────────────────► │ socat on Mac (:9222)    │
│ puppeteer-   │                              │        │                │
│ core/        │                              │        ▼                │
│ playwright   │                              │ Chrome --remote-debug...│
└──────────────┘                              │   (profile: ~/chrome-   │
                                              │    remote-profile)      │
                                              └─────────────────────────┘
```

- Chrome runs with a **dedicated automation profile** at `~/chrome-remote-profile`
  so your normal browsing isn't touched.
- CDP binds to `127.0.0.1:9222`.
- `socat` bridges the port onto the Tailscale interface (`100.78.207.22:9222`)
  so only tailnet peers can reach it — nothing is exposed to the public internet.

## Files

- `mac-setup/chrome-cdp.sh` — idempotent launcher; kills prior instances + socat
  then starts fresh. Uses `nohup` + `disown` so Chrome survives the script exiting.
- `mac-setup/com.wrkflo.chrome-cdp.plist` — LaunchAgent (`com.wrkflo.chrome-cdp`)
  that runs the launcher on login so CDP is always available.
- `scripts/control-mac-chrome.js` — puppeteer-core example: connect, list tabs,
  open a new one, screenshot.
- `scripts/control-mac-chrome.sh` — wrapper that sets `NODE_PATH` to the global
  npm root so the global `puppeteer-core` and `playwright-core` resolve.

## Usage from the VM

```bash
# sanity check
curl http://100.78.207.22:9222/json/version

# run the example (puppeteer-core globally installed)
~/projects/dev-workspace/scripts/control-mac-chrome.sh
```

### Puppeteer

```js
const puppeteer = require('puppeteer-core');
const browser = await puppeteer.connect({ browserURL: 'http://100.78.207.22:9222' });
```

### Playwright

```js
const { chromium } = require('playwright-core');
const browser = await chromium.connectOverCDP('http://100.78.207.22:9222');
```

## Troubleshooting

- **`ECONNREFUSED 100.78.207.22:9222`** — socat or Chrome died. Re-run
  `mac-setup/chrome-cdp.sh` on the Mac. `launchctl list | grep wrkflo`
  should show the agent.
- **Tabs from your regular Chrome don't appear** — intentional. The
  automation profile is isolated. If you want codex to interact with a
  logged-in service, sign into that service inside the automation profile's
  Chrome window once; cookies/session will persist across restarts.
- **Opening the Chrome window by hand** — the script ran with a GUI, so the
  dock icon appears. You can interact with that window like any other Chrome.

## Security

CDP has no authentication — anyone who can hit `100.78.207.22:9222` has full
browser control inside that profile. Tailscale ACLs default to
"tailnet-internal only." If you share your tailnet with other users, add an
ACL rule restricting port 9222 to your own devices.
