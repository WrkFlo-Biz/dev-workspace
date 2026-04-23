# Phone control (best-effort, given iOS limits)

iOS doesn't allow an SSH server, shell, or remote-desktop listener to run in
the background, so "type commands that execute on the phone" the way you can
on the Mac isn't possible. What **is** possible is a **push + action** loop:

- VM pushes a message / action request to the phone.
- Phone shows a banner; you tap it.
- The tap can open a URL, run a Shortcut, or kick off an automation locally.
- The Shortcut can call back to the VM over HTTPS with the result.

That covers most "the agent wants me to do X on the phone" cases without
breaking iOS's sandbox model.

## What's installed

On the VM: `~/bin/push-phone`. Uses ntfy.sh as the relay with a private
random topic name (kept inside the script — change `$TOPIC` to rotate).

```bash
push-phone "Build finished"                       # body
push-phone --title "PR review" "https://..."      # custom title
push-phone --url "https://…/pr/42" "Approve?"     # tap-through URL
push-phone --priority 5 "ALERT: prod 500s"        # loud/urgent
```

## Phone setup

1. Install **ntfy** from the App Store (free,
   <https://apps.apple.com/us/app/ntfy/id1625396347>).
2. Open ntfy → Add subscription → Topic name = the one saved in
   `~/bin/push-phone` on the VM (`grep TOPIC= ~/bin/push-phone`).
3. Leave "Server" as the default (`ntfy.sh`).
4. Test from the VM: `push-phone "hello from VM"`.
   You should see a banner within a second or two.

## Shortcuts template (optional but powerful)

To get the "tap a push → run a local Shortcut → call back to VM" loop:

1. iPhone → Shortcuts app → **+** → create a shortcut called "dws-action".
2. First action: **URL** → set to `http://100.117.16.63:8081/pending`
   (the VM's Tailscale IP + a port you run a small HTTP server on; see
   `scripts/dws-phone-server.py` for a starter).
3. Add **Get Contents of URL** (method GET).
4. Add **Get Dictionary Value** → key `action`.
5. Add **If** branches for the actions you care about (Open URL, Play Sound,
   Send iMessage, Run Shell Script on Mac via SSH, etc.).
6. Back in ntfy, long-press the topic → **Notification action** → add an
   action that runs shortcut `dws-action` on tap.

Example actions the Shortcut can perform locally on the phone:

- Open any URL (Termius, Working Copy, Safari to a PR)
- Start a timer / reminder
- Speak text (Text-to-Speech)
- Run JavaScript in Safari (DOM inspection)
- Send a pre-populated Message / Mail
- Play a specific alarm sound

## What you still cannot do

- Remotely type into a phone app as if it were a desktop
- Observe the phone screen from the VM
- Read arbitrary files off the phone (only things the Shortcut explicitly
  uploads or the user saves to iCloud Drive)
- Run arbitrary shell on iOS

For those, the practical alternative is to keep the workflow **on the Mac or
the VM** and use the phone purely as a trigger / display.

## Security

- ntfy.sh is a public relay. Topic names are secret-equivalent — anyone who
  guesses the topic can both send and read. Treat `$TOPIC` as sensitive.
  Rotate by editing `~/bin/push-phone` and re-subscribing on the phone.
- If you want stronger isolation, self-host ntfy on the VM (just the binary
  plus a systemd unit) and point the iOS app at it via the Tailscale IP.
