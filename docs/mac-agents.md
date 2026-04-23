# Mac LaunchAgents Review

Investigation date: 2026-04-23 UTC.

Scope:

- `com.wrkflo.mac-bridges`
- `com.wrkflo.global-sentinel-sync`

These findings are based on the installed LaunchAgents on the Mac under
`/Users/mosestut/Library/LaunchAgents/`, plus the scripts they currently call.

## Executive summary

- Neither LaunchAgent is "running" right now, but that is not automatically a
  problem. Both are configured as short-lived jobs, not long-lived daemons.
- `com.wrkflo.mac-bridges` is a legacy bridge bootstrapper. On the live Mac,
  its job has effectively been replaced by two newer always-on LaunchAgents:
  `com.wrkflo.chrome-cdp-relay` and `com.wrkflo.hammerspoon-relay`.
- `com.wrkflo.global-sentinel-sync` is not repo-managed. It points at an
  untracked local script and appears to be a leftover convenience job for a
  Mac-local `global-sentinel` workflow that is not part of the current
  `dev-workspace` repo.

## `com.wrkflo.mac-bridges`

Installed plist on the Mac:

```xml
<key>Label</key>
<string>com.wrkflo.mac-bridges</string>
<key>ProgramArguments</key>
<array>
  <string>/bin/bash</string>
  <string>-lc</string>
  <string>/Users/mosestut/dev-workspace/mac-setup/mac-bridges.sh</string>
</array>
<key>RunAtLoad</key>
<true/>
<key>StandardOutPath</key>
<string>/tmp/mac-bridges.out.log</string>
<key>StandardErrorPath</key>
<string>/tmp/mac-bridges.err.log</string>
```

Live `launchctl` state:

- `state = not running`
- `runs = 1`
- `last exit code = 0`

### What it does

The tracked script it runs is `mac-setup/mac-bridges.sh`.

That script:

- checks the current Tailscale IPv4 address
- ensures Chrome DevTools is reachable on localhost `:9222`
- ensures the Hammerspoon HTTP API is reachable on localhost `:9223`
- uses `socat` to bind those services onto the Mac's Tailscale IP
- writes logs to `/tmp/mac-bridges.out.log`, `/tmp/mac-bridges.err.log`, and
  `/tmp/socat-*.log`

The last bridge log on the Mac shows a successful run:

- Chrome CDP bridged on `100.78.207.22:9222`
- Hammerspoon bridged on `100.78.207.22:9223`
- both endpoints responding

### Important drift

The installed plist on the Mac is older than the repo copy.

Repo copy in `mac-setup/com.wrkflo.mac-bridges.plist` includes:

- `RunAtLoad = true`
- `StartInterval = 60`

Installed Mac copy includes:

- `RunAtLoad = true`
- no `StartInterval`

That means the live Mac agent is a one-shot login hook, not the periodic
rechecker described in repo docs such as `docs/architecture.md`.

### Is it still needed?

For the live Mac as it exists today: probably **no**.

Reason:

- The Mac currently has two newer active LaunchAgents:
  - `com.wrkflo.chrome-cdp-relay`
  - `com.wrkflo.hammerspoon-relay`
- Both are `KeepAlive = true` jobs.
- Both are running right now.
- Both keep the actual required ports up:
  - `127.0.0.1:9222` and `100.78.207.22:9222`
  - `127.0.0.1:9223` and `100.78.207.22:9223`

So the live bridge function is already being handled elsewhere.

For the repo as source of truth: still **yes, for now**.

Reason:

- `com.wrkflo.mac-bridges.plist` and `mac-setup/mac-bridges.sh` are tracked.
- `mac-setup/mac-setup.sh`, `scripts/dws-sync-mac.sh`, the architecture docs,
  and the remote-control docs still refer to `com.wrkflo.mac-bridges`.
- The replacement relay agents are not tracked in this repo.

Recommendation:

- Treat the installed `com.wrkflo.mac-bridges` agent as legacy on this Mac.
- Do not rely on it as the active production path.
- If the relay agents are the intended future state, move them into the repo
  and then remove `com.wrkflo.mac-bridges` from docs and install tooling.
- If the repo-managed bridge path is still the intended path, reinstall the
  tracked plist so the Mac gets back the documented `StartInterval = 60`
  behavior.

## `com.wrkflo.global-sentinel-sync`

Installed plist on the Mac:

```xml
<key>Label</key>
<string>com.wrkflo.global-sentinel-sync</string>
<key>ProgramArguments</key>
<array>
  <string>/bin/bash</string>
  <string>-lc</string>
  <string>GLOBAL_SENTINEL_SYNC_LOGIN=1 /Users/mosestut/dev-workspace/scripts/global-sentinel-sync.sh</string>
</array>
<key>RunAtLoad</key>
<true/>
<key>StartInterval</key>
<integer>300</integer>
<key>StandardOutPath</key>
<string>/tmp/global-sentinel-sync.out.log</string>
<key>StandardErrorPath</key>
<string>/tmp/global-sentinel-sync.err.log</string>
```

Live `launchctl` state:

- `state = not running`
- `runs = 62`
- `last exit code = 0`
- `run interval = 300 seconds`

### What it does

This agent calls:

```text
/Users/mosestut/dev-workspace/scripts/global-sentinel-sync.sh
```

That script is **not tracked** in the current repo.

Current script behavior on the Mac:

- uses `GS_LOCAL="$HOME/global-sentinel"`
- checks whether `~/global-sentinel/.git` exists
- pings `dev-workspace-vm`
- if the Mac repo is clean, fetches and rebases `origin/main`
- if `~/global-sentinel/data/analysis` exists, rsyncs it to:
  `moses@dev-workspace-vm:projects/global-sentinel/data/analysis/`

### Current usefulness on this Mac

This looks low-value today.

Observed facts:

- `scripts/global-sentinel-sync.sh` is untracked in `~/dev-workspace` on the
  Mac.
- The Linux checkout of this repo has no `scripts/global-sentinel-sync.sh`.
- Repo search found no references to `com.wrkflo.global-sentinel-sync`.
- The Mac has `~/global-sentinel`, but there is no
  `~/global-sentinel/data/analysis` directory right now.
- Recent stdout only shows repeated `dirty working tree, skipping git pull`.
- There is no evidence in the log of a successful analysis-data rsync.

So today the agent mostly wakes up every five minutes, notices the local
`global-sentinel` repo is dirty, skips the git pull, and then has no analysis
directory to sync.

### Is it still needed?

Probably **no**.

Reason:

- It is outside the repo's supported surface area.
- It depends on an untracked local script.
- It references a Mac-local `~/global-sentinel` workflow rather than the normal
  VM-first `~/projects/global-sentinel` workflow.
- It does not appear to be transferring any data right now.

Recommendation:

- Remove the LaunchAgent unless there is a known off-repo workflow that still
  depends on `~/global-sentinel/data/analysis` being pushed from the Mac to the
  VM.
- If that workflow is still real, move the script into version control and
  document the source and destination directories explicitly.

## Bottom line

- `com.wrkflo.mac-bridges`: legacy on the live Mac, but still part of the
  repo's documented install path. It should either be reinstated from the
  tracked plist or formally replaced in the repo by the newer relay agents.
- `com.wrkflo.global-sentinel-sync`: local-only legacy automation. It is not
  repo-managed and does not appear to be doing useful work now.
