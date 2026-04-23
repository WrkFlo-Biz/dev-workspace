# Troubleshooting

Common failures in `dev-workspace` and the shortest path to recovery.

## Fast Triage

When something looks wrong, start here before editing queue state or restarting loops:

```bash
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
~/projects/dev-workspace/bin/dws-sessions.sh list
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```

If those disagree with each other, trust the user-service state and
`/var/log/dws/monitor.log` first. Inspect the raw queue only after the service
log and `tmux` state line up:

```bash
jq -r '.tasks[]? | select(.status=="in_progress") | [.id,.assigned,.repo] | @tsv' \
  ~/projects/dev-workspace/.state/task-queue.json
```

## SSH Drops

Symptoms:
- Termius or Terminal disconnects mid-session
- Phone sleeps and the SSH session dies

Fix:
1. Reconnect to `moses@dev-workspace-vm` over Tailscale
2. In the launcher, press `r` to reconnect to the last `tmux` session
3. If needed, run `~/projects/dev-workspace/bin/dws-sessions.sh list` and reconnect by name with `~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>`

Checks:
- Prefer `dev-workspace-vm` over the public IP; use `20.230.203.79` only as fallback.
- If reconnect fails entirely, verify Tailscale on both devices and rerun `~/projects/dev-workspace/scripts/dws-health.sh`.

## SSH Lockout Recovery

Symptoms:
- A new SSH login fails after an `sshd` or key change
- `Permission denied (publickey)` appears even though the VM is still up
- You still have one surviving shell, `tmux` client, Tailscale session, or Azure serial-console path

Fix:
1. Inspect the live SSH config and service state from the surviving shell before changing anything:

```bash
sudo sh -c 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -e "$f" ] || continue; echo "--- $f ---"; sed -n "1,200p" "$f"; done'
sudo sshd -t
systemctl is-active ssh ssh.socket sshd sshd.socket
```

2. If a hardening drop-in caused the lockout, disable it and reload SSH:

```bash
sudo mv /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf.disabled 2>/dev/null || true
sudo mv /etc/ssh/sshd_config.d/zz-dws-hardening.conf /etc/ssh/sshd_config.d/zz-dws-hardening.conf.disabled 2>/dev/null || true
sudo mv /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf /etc/ssh/sshd_config.d/99-dev-workspace-hardening.conf.disabled 2>/dev/null || true
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

3. Restore the repo-managed baseline only after a fresh login works again:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo install -m 0644 ~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl restart ssh
```

4. Verify keys and recent SSH outcomes before you close the last working shell:

```bash
ls -l ~/.ssh/authorized_keys ~/.ssh/termius_20260415 ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null
journalctl -u ssh --since '24 hours ago' --no-pager | rg 'Accepted publickey|Failed publickey|Failed password'
```

Notes:
- Keep one working shell open until a second login succeeds.
- `~/projects/dev-workspace/config/ssh/zz-dws-hardening.conf` is the repo-managed SSH baseline; on this VM it is currently installed as `/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf`.

## Tailscale Reconnection

Symptoms:
- `ssh moses@dev-workspace-vm` fails on MagicDNS or Tailscale IP
- `~/projects/dev-workspace/bin/dws-doctor.sh` reports Tailscale disconnected
- The VM is up, but nothing on the tailnet can reach it

Fix:
1. Run the repo diagnostics first:

```bash
~/projects/dev-workspace/bin/dws-tailscale-diag.sh
~/projects/dev-workspace/bin/dws-connect-test.sh
```

2. Check the raw Tailscale state on the VM:

```bash
tailscale status
tailscale ip -4
sudo systemctl status tailscaled --no-pager
```

3. If `tailscaled` is down or wedged, restart it and bring the VM back onto the tailnet:

```bash
sudo systemctl restart tailscaled
sudo tailscale up --ssh --operator=moses --hostname=dev-workspace-vm
tailscale status
tailscale ip -4
```

4. Confirm the VM can see the other operator devices again:

```bash
tailscale ping 100.78.207.22
tailscale ping 100.88.249.22
```

If MagicDNS is the only thing broken on the affected client:

```bash
tailscale up --accept-dns=true
```

## Foundry Key Missing

Symptoms:
- The launcher or status page shows `key=missing`
- Codex requests fail because `AZURE_OPENAI_API_KEY` is not loaded

Fix:
1. Check the env file: `ls -l ~/.config/wrkflo/foundry.env`
2. Load it into the current shell: `. ~/.config/wrkflo/foundry.env`
3. Re-run `~/projects/dev-workspace/bin/dws-status.sh` and confirm the key state clears

If the file is missing:
1. Ensure `az login` works on the VM
2. Re-run `~/projects/dev-workspace/scripts/vm-bootstrap.sh` or fetch the key again through Azure

## tmux Session Recovery

Symptoms:
- SSH reconnects but your Codex or Claude session is gone from the terminal
- The launcher appears, but your agent is still running somewhere else

Fix:
1. Run `~/projects/dev-workspace/bin/dws-sessions.sh list`
2. Inspect one session with `~/projects/dev-workspace/bin/dws-sessions.sh show <session>` to see the crash marker, last task, and recovery hints
3. Reattach with `~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>`
4. From inside `tmux`, use `Ctrl-a d` to detach cleanly instead of closing the shell

If a stale session blocks relaunch:
1. Try an in-place restart with `~/projects/dev-workspace/bin/dws-sessions.sh recover <session>`
2. If you want a fresh worker instead, run `~/projects/dev-workspace/bin/dws-sessions.sh relaunch <session>`
3. Kill it with `~/projects/dev-workspace/bin/dws-sessions.sh kill <session>` only if the recover or relaunch path is wrong

Notes:
- `list` plus `show` are the current session-history and recovery views; there is no separate `session-history` command.
- `show` is the quickest way to grab the last task text before you recover or relaunch a worker.

## Codex Compaction Recovery

Symptoms:
- Codex exits unexpectedly after a long session
- You see a compaction or context failure and drop back to `Session ended. [r]estart / [q]uit:`

Fix:
1. Pull the session, pane, and monitor evidence before you restart anything:

```bash
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
tmux capture-pane -t <session> -p | tail -n 40
grep -E 'COMPACTED|compact task|high demand' /var/log/dws/monitor.log | tail -n 20
```

2. If the pane is still at the restart prompt, press `r` once to retry inside the same `tmux` session.
3. If the same session should continue, run `~/projects/dev-workspace/bin/dws-sessions.sh recover <session>`.
4. If compaction repeats or the context is obviously too large, run `~/projects/dev-workspace/bin/dws-sessions.sh relaunch <session>`.
5. Before relaunching, copy the last task text out of `show` or `/var/log/dws/monitor.log` and leave a short handoff note in the repo.

If it keeps happening:
1. Start a new session with a cleaner prompt and smaller working set
2. Move long logs or giant pasted blobs out of the active conversation
3. Prefer `gpt-5.4` for harder recovery work if the smaller profile is struggling

## Task-Monitor Restart

Symptoms:
- `~/projects/dev-workspace/bin/dws-doctor.sh` reports stale or failed monitor artifacts
- `dws-task-monitor.service` is inactive or `/var/log/dws/monitor.log` stops advancing
- Queue-backed workers stop relaunching even though the queue still has work

Fix:
1. Check the runtime before the restart:

```bash
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
systemctl --user status dws-task-monitor.service --no-pager
journalctl --user -u dws-task-monitor.service -n 40 --no-pager
tail -n 40 /var/log/dws/monitor.log
sed -n '1,120p' ~/projects/dev-workspace/.state/task-queue.json
tmux list-sessions
```

2. Restart the monitor service:

```bash
systemctl --user restart dws-task-monitor.service
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```

3. If the whole worker pool disappeared after reboot or a bad deploy, rebuild the managed `tmux` sessions:

```bash
systemctl --user restart dws-sessions-init.service
tmux list-sessions
```

4. If the installed units are missing or stale, reinstall them and rerun both services:

```bash
~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install
systemctl --user daemon-reload
systemctl --user restart dws-sessions-init.service
systemctl --user restart dws-task-monitor.service
```

5. Re-run `~/projects/dev-workspace/bin/dws-status.sh` and `~/projects/dev-workspace/bin/dws-doctor.sh` until the runtime artifacts go fresh again.

Notes:
- The normal monitor recovery path is the user service, not a dedicated `monitor` `tmux` session.
- `scripts/dws-doctor.sh` still reads some legacy `/tmp/*` artifacts by default, so let `systemctl --user` plus `/var/log/dws/monitor.log` break ties if the tools disagree.

## Firewall Rollback

Symptoms:
- SSH or dev ports stop working immediately after `bin/dws-firewall.sh`
- `ufw` or `iptables` rules no longer match the expected Tailscale-first policy
- You need to get back to the previous open state before trying a cleaner rollout

Fix:
1. Snapshot the current firewall state before rollback:

```bash
sudo ufw status numbered 2>/dev/null || true
sudo iptables -S 2>/dev/null || true
sudo nft list ruleset 2>/dev/null | sed -n '1,120p' || true
```

2. If the host is using `ufw`, disable it immediately:

```bash
sudo ufw --force disable
sudo ufw status verbose
```

3. If the host is using the repo `iptables` chain, remove it cleanly:

```bash
sudo iptables -w -D INPUT -j DWS_FIREWALL_INPUT 2>/dev/null || true
sudo iptables -w -F DWS_FIREWALL_INPUT 2>/dev/null || true
sudo iptables -w -X DWS_FIREWALL_INPUT 2>/dev/null || true
sudo iptables -S | sed -n '1,120p'
```

4. If `netfilter-persistent` is installed, save the rollback state:

```bash
sudo netfilter-persistent save
```

5. If you persist rules through `/etc/iptables/rules.v4` instead, rewrite that file:

```bash
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
```

6. Reapply the repo policy only after SSH and Tailscale are stable again:

```bash
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend ufw
sudo ~/projects/dev-workspace/bin/dws-firewall.sh --backend iptables
```

Notes:
- `bin/dws-firewall.sh` prefers `ufw` when it is installed.
- `udp/41641`, `tcp/22`, `tcp/8080`, `tcp/9222`, and `tcp/3000` are the repo-managed inbound allow rules.

## Queue Repair And Backup Prune

Symptoms:
- The queue stays stale or inconsistent after the runtime loops restart
- Tasks remain `in_progress` for workers that no longer exist
- You need to validate or prune backup artifacts while recovering runtime state

Fix:
1. Snapshot the live runtime first: `~/projects/dev-workspace/bin/dws-backup.sh backup`
2. Validate the latest snapshot and prune expired backup artifacts in one pass: `~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest --prune`
3. Validate the queue file itself: `jq . ~/projects/dev-workspace/.state/task-queue.json >/dev/null`
4. Compare queue assignments to live worker state with `~/projects/dev-workspace/bin/dws-sessions.sh list`
5. If the queue is corrupted or obviously older than the newest snapshot, restore it: `~/projects/dev-workspace/bin/dws-backup.sh restore latest`
6. Restart planner and monitor after queue repair so they reread the corrected state

Notes:
- There is no separate `backup-prune` command. Use `verify-restore --prune` or `~/projects/dev-workspace/bin/dws-backup.sh cron`.
- `verify-restore` prints the temp restore directory path on failure so you can inspect the broken snapshot directly.

## Phone / Termius Issues

Symptoms:
- The iPhone connects to Tailscale but Termius still cannot log in
- Termius opens a shell but the launcher does not appear
- You need to rebuild the exact phone host settings or confirm which SSH key the phone should import

Fix:
1. Print the current VM host values and recommended Termius settings:

```bash
~/projects/dev-workspace/bin/dws-termius-setup.sh
```

2. Verify that the expected private key exists on the trusted desktop or Mac before you reimport it on the phone:

```bash
ls -l ~/.ssh/termius_20260415 ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null
```

3. Confirm the same key can still reach the VM from a desktop shell:

```bash
DWS_TERMIUS_KEY="$(~/projects/dev-workspace/bin/dws-termius-setup.sh | sed -n 's/^  SSH key path: \([^ ]*\) (.*/\1/p')"
ssh -i "$DWS_TERMIUS_KEY" -o BatchMode=yes -o ConnectTimeout=5 moses@100.117.16.63 'printf phone-key-ok\n'
```

4. If the login works but the launcher is skipped, clear the bypass and start it manually:

```bash
unset SKIP_LAUNCHER
~/bin/dws-launcher.sh
```

5. If the phone login reaches the VM but not the right worker, reattach directly:

```bash
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh reconnect
~/projects/dev-workspace/bin/dws-sessions.sh reconnect <session>
```

6. Verify the phone path on the VM side:

```bash
journalctl -u ssh --since '24 hours ago' --no-pager | rg '100\.88\.249\.22|iphone-15-pro-max|Accepted publickey|Failed publickey'
```

Notes:
- The recommended Termius keepalive is `30` seconds and the startup command should stay blank unless you intentionally want to bypass the launcher.
- Use landscape mode when you are actively working inside `tmux`, Codex, or Claude.

## Useful Commands

```bash
~/projects/dev-workspace/bin/dws-status.sh
~/projects/dev-workspace/bin/dws-doctor.sh
~/projects/dev-workspace/bin/dws-health-full.sh
~/projects/dev-workspace/bin/dws-sessions.sh list
~/projects/dev-workspace/bin/dws-sessions.sh show <session>
~/projects/dev-workspace/bin/dws-sessions.sh recover <session>
~/projects/dev-workspace/bin/dws-sessions.sh relaunch <session>
~/projects/dev-workspace/bin/dws-sessions-init.sh --force
~/projects/dev-workspace/bin/dws-backup.sh verify-restore latest --prune
~/projects/dev-workspace/bin/dws-tailscale-diag.sh
~/projects/dev-workspace/bin/dws-connect-test.sh
~/projects/dev-workspace/bin/dws-termius-setup.sh
~/projects/dev-workspace/bin/dws-firewall.sh --dry-run
~/projects/dev-workspace/scripts/dws-launcher.sh status
~/projects/dev-workspace/scripts/dws-health.sh --json
~/projects/dev-workspace/scripts/dws-quick.sh gs codex
systemctl --user status dws-task-monitor.service --no-pager
tail -n 40 /var/log/dws/monitor.log
```

See also `docs/runbook.md`, `docs/live-access-truth.md`, `docs/termius.md`, `docs/termius-setup.md`, and `docs/tailscale.md`.
