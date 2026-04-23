# Phone control (VM ⇄ iPhone)

The closest thing iOS permits to "control my phone from the terminal":

```
 VM                                             iPhone
 ───                                            ──────
 push-phone --action open_url …       ─ntfy─►   banner notification
                                                (user taps)
                                                     │
                                                 shortcuts://run-shortcut?name=dws-action
                                                     │
                                                     ▼
                                                Shortcut "dws-action"
                                                     │
     GET /pending  ◄───────────────────────────── HTTP over Tailscale
     → {"action":"open_url","url":"…"}             │
                                                     │
                                                 perform locally (Open URL,
                                                 Speak Text, iMessage, …)
                                                     │
     POST /result  ◄───────────────────────────── optional callback
```

## Pieces

### VM

- `~/bin/dws-phone-server.py` — tiny stdlib HTTP server on port `8081` with
  a command queue and a results log. Runs as systemd user unit
  `dws-phone-server.service`.
- `~/bin/push-phone` — shell helper. Sends an ntfy.sh notification and, if
  `--action` is passed, queues the action on the phone server and sets the
  notification's tap URL to `shortcuts://run-shortcut?name=dws-action`.

### iPhone

- **ntfy** app from the App Store (free). Subscribed to topic
  **`wrkflo-36953b08d28a`** on server `ntfy.sh`.
- **Shortcuts** app — build one named `dws-action` (see below).
- **Tailscale** app — already installed. The Shortcut hits the VM over
  the mesh.

## Using it from the VM

```bash
# Plain banner
push-phone "deploy finished"

# Tappable action: open a URL on the phone
push-phone --action open_url --data "https://github.com/Wrk-Flo/dev-workspace" \
  --title "PR" "tap to open the repo"

# Speak a message through the phone's TTS
push-phone --action speak --data "Moses, coffee is ready" "tap to speak"

# Copy text into the phone's clipboard
push-phone --action copy --data "API_KEY_abcdef123" "tap to copy"

# Send an iMessage (phone asks to confirm first time)
push-phone --action message --data "+15555551234|running late" "tap to send"

# Loud / alert priority
push-phone --priority 5 --title "ALERT" "prod 500s"
```

Each `--action …` enqueues one JSON blob on the VM. The Shortcut pops the
next blob off the queue when you tap.

## Building the `dws-action` Shortcut (one-time, on the phone)

Open **Shortcuts** on the iPhone → bottom right **+** → name it **`dws-action`**.
Add these actions in order:

1. **Get Contents of URL**
   - URL: `http://100.117.16.63:8081/pending`
   - Method: `GET`
2. **Get Dictionary Value**
   - Get: `Value`
   - Key: `action`
   - Dictionary: the output of step 1
3. **If** `Dictionary Value` `is` `open_url`
   - **Get Dictionary Value** key `url` from the original dictionary
   - **Open URLs** → the value above
4. **Otherwise If** `action` `is` `speak`
   - **Get Dictionary Value** key `text`
   - **Speak Text** → that value
5. **Otherwise If** `action` `is` `copy`
   - **Get Dictionary Value** key `text`
   - **Copy to Clipboard** → that value
6. **Otherwise If** `action` `is` `message`
   - **Get Dictionary Value** key `to` → store as variable `To`
   - **Get Dictionary Value** key `body` → store as variable `Body`
   - **Send Message** → Recipients = `To`, Message = `Body`
7. **End If**

Save. First run prompts for:
- Network permission (Allow)
- Permission per action (Send Messages, etc. — Allow each)

**Test:** on the VM run `push-phone --action speak --data "hi" "tap"`, tap
the banner; the phone should speak "hi".

## Handy snippets to paste in Termius

| Snippet           | Command                                                            |
|-------------------|--------------------------------------------------------------------|
| Push me           | `push-phone "$(date)"`                                             |
| Alert             | `push-phone --priority 5 --title ALERT "$*"`                       |
| Open URL on phone | `push-phone --action open_url --data "$1" "tap to open"`           |
| Copy to phone     | `push-phone --action copy     --data "$1" "tap to copy"`           |

## Security

- The ntfy topic name is secret-equivalent. Anyone who knows
  `wrkflo-36953b08d28a` can both send banners to the phone and read the
  messages. Treat it like a password. Rotate by editing the `TOPIC=` line in
  `~/bin/push-phone` and re-subscribing on the phone.
- The callback server binds to `0.0.0.0:8081` on the VM, but Azure's NSG
  only exposes port 22 publicly, so only tailnet peers can actually reach it.
- Every queued item is popped once and then gone; there is no per-request
  auth. Add a shared-secret header if you ever share your tailnet.

## Limits that still exist

- No way to run arbitrary shell on iOS — Apple blocks it.
- No background poll. The Shortcut only runs when you tap the banner (or
  manually run it, or bind it to a Back Tap / Siri / HomePod trigger).
- The Shortcut can only do things iOS Shortcuts natively supports. Anything
  that needs a third-party app needs that app to expose a Shortcut action.
