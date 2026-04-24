# Mac remote control (VM → Mac GUI)

Two endpoints bridge the Mac's GUI to codex on the dev-workspace VM:

| Port | Service      | What it gives you                                  |
|------|--------------|----------------------------------------------------|
| 9222 | Chrome CDP   | puppeteer/playwright: navigate, click, DOM, JS     |
| 9223 | Hammerspoon  | OS-level: open apps, menus, osascript, keystrokes  |

Both are bound to `127.0.0.1` on the Mac and bridged to the Tailscale
interface (`100.78.207.22`) via `socat`, so only tailnet peers can reach them.

## Hammerspoon HTTP API (port 9223)

All endpoints are `POST` with JSON bodies. Return `{"ok": true, ...}` on
success, `{"ok": false, "error": ...}` on failure.

| Path             | Body                                                   | Effect |
|------------------|--------------------------------------------------------|--------|
| `/osascript`     | `{"script": "..."}` (AppleScript source)               | Runs AppleScript; returns result as string |
| `/open`          | `{"app": "Safari"}`                                    | `launchOrFocus(app)`                       |
| `/open_url`      | `{"url": "https://..."}`                               | Opens URL in default browser               |
| `/spotlight`     | `{"query": "Notes"}`                                   | Cmd-Space, type, press Enter               |
| `/click_menu`    | `{"app": "Safari", "path": ["File","New Window"]}`     | Selects a menu item in a given app         |
| `/type`          | `{"text": "hello"}`                                    | `keyStrokes(text)` into focused field      |
| `/keystroke`     | `{"keys": "cmd+shift+4"}`                              | Press a key combo                          |
| `/screenshot`    | `{}`                                                   | Returns `{png_base64: "..."}` of main screen |
| `/focused`       | `{}`                                                   | Window + app info                          |
| `/apps`          | `{}`                                                   | List running apps                          |

### Examples from the VM

```bash
# Open Notes and create a new note
curl -fsS -X POST http://100.78.207.22:9223/open \
  -H 'Content-Type: application/json' \
  -d '{"app":"Notes"}'

curl -fsS -X POST http://100.78.207.22:9223/click_menu \
  -H 'Content-Type: application/json' \
  -d '{"app":"Notes","path":["File","New Note"]}'

curl -fsS -X POST http://100.78.207.22:9223/type \
  -H 'Content-Type: application/json' \
  -d '{"text":"Meeting notes for today\n\n- Item 1\n- Item 2"}'

# Run arbitrary AppleScript
curl -fsS -X POST http://100.78.207.22:9223/osascript \
  -H 'Content-Type: application/json' \
  -d '{"script":"tell application \"Messages\" to send \"hi\" to buddy \"+15555551234\" of service 1"}'

# Screenshot the Mac
curl -fsS -X POST http://100.78.207.22:9223/screenshot \
  -H 'Content-Type: application/json' -d '{}' \
  | jq -r .png_base64 | base64 -d > /tmp/mac-screen.png
```

## One-time Mac permissions you must grant

When Hammerspoon or Chrome want to do certain things macOS prompts for
consent. Go to **System Settings → Privacy & Security** and make sure
Hammerspoon is checked under each of:

- **Accessibility** — required for keystrokes, menu clicks, window ops
- **Screen Recording** — required for `/screenshot`
- **Automation** — granted per-target-app the first time you run
  `/osascript` against a given app (prompt appears on the Mac)

Without these toggles, calls return `{"ok": false, "error": "..."}`.

## Services and files

- `mac-setup/mac-bridges.sh` — (re)starts Chrome + Hammerspoon + socat bridges.
- `mac-setup/chrome-cdp.sh` — Chrome CDP helper (used by mac-bridges.sh).
- `mac-setup/com.wrkflo.mac-bridges.plist` — LaunchAgent that runs
  mac-bridges.sh on login. Install it into the Mac user's LaunchAgents
  directory when you wire up the local service.
- `~/.hammerspoon/init.lua` — the Hammerspoon HTTP API implementation.
- `scripts/control-mac-chrome.js` + `.sh` — VM-side puppeteer example.
- `scripts/control-mac-gui.py` — VM-side wrapper for the `9223` Hammerspoon API.

### VM helper script

On the VM, use the helper instead of raw `curl` when you want AppleScript or
GUI actions from Linux:

```bash
~/projects/dev-workspace/scripts/control-mac-gui.py focused
~/projects/dev-workspace/scripts/control-mac-gui.py open "Terminal"
~/projects/dev-workspace/scripts/control-mac-gui.py osascript \
  'tell application "Terminal" to do script "pwd" in front window'
~/projects/dev-workspace/scripts/control-mac-gui.py click-menu "Safari" "File" "New Window"
~/projects/dev-workspace/scripts/control-mac-gui.py screenshot --out /tmp/mac-screen.png
```

## Debugging

| Symptom                              | Check                                                                                   |
|--------------------------------------|-----------------------------------------------------------------------------------------|
| `ECONNREFUSED 100.78.207.22:9222/9223` | `launchctl list \| grep wrkflo` — if missing or exit code non-zero, run `mac-bridges.sh` |
| `/screenshot` returns error          | Grant Screen Recording perm to Hammerspoon                                              |
| Keystrokes do nothing                | Grant Accessibility perm to Hammerspoon                                                 |
| `/osascript` on a new app errors     | macOS Automation prompt — click Allow on the Mac, then retry                            |
| socat dies                           | Check `/tmp/socat-*.log`                                                                |
