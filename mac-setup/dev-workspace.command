#!/bin/bash
# Double-click on Mac → SSH to VM → launcher handles project/model/tmux.
# Uses Tailscale hostname, falls back to public IP.

HOST=dev-workspace-vm
ping -c1 -W1 "$HOST" >/dev/null 2>&1 || HOST=20.230.203.79

exec ssh -t "moses@$HOST" "bash -l"
