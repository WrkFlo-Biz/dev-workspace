#!/usr/bin/env bash
# terminal-reconnect.sh — monitor Mac Terminal.app windows for dropped SSH
# connections and auto-reconnect them to their tmux sessions on the VM.
# LaunchAgent: com.wrkflo.terminal-reconnect (runs every 30s)

set -o pipefail

LOG="/tmp/terminal-reconnect.log"
VM="moses@dev-workspace-vm"
EXPECTED_SESSIONS=(dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h orchestrator)

log() { printf '%s [reconnect] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

# Get all Terminal window IDs and their names via osascript
get_windows() {
  osascript -e '
tell application "Terminal"
  set output to ""
  repeat with w in windows
    set output to output & (id of w) & "|||" & (name of w) & "\n"
  end repeat
  return output
end tell' 2>/dev/null
}

# Check if a tmux session exists on the VM
session_exists() {
  ssh -o ConnectTimeout=3 -o BatchMode=yes "$VM" "tmux has-session -t '$1' 2>/dev/null" 2>/dev/null
}

# Reconnect a Terminal window to a tmux session
reconnect_window() {
  local wid="$1" session="$2"
  osascript -e "
tell application \"Terminal\"
  do script \"ssh $VM -t 'tmux attach-session -t $session'\" in window id $wid
end tell" 2>/dev/null
  log "reconnected window $wid -> $session"
}

# Map a window to its original session by checking tab history
# Terminal windows that were attached to tmux show the session name in their title
# When SSH drops, the title shows "-zsh" but we can check other tabs
find_session_for_window() {
  local wid="$1"
  # Check all tabs in this window for a session name hint
  local tab_names
  tab_names=$(osascript -e "
tell application \"Terminal\"
  set w to window id $wid
  set output to \"\"
  repeat with t in tabs of w
    set output to output & (history of t) & \"|||\"
  end repeat
  return output
end tell" 2>/dev/null)

  # Search history for tmux attach patterns
  for session in "${EXPECTED_SESSIONS[@]}"; do
    if echo "$tab_names" | grep -q "$session"; then
      echo "$session"
      return
    fi
  done
  echo ""
}

# ── Main ──

# Check VM is reachable first
if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$VM" "true" 2>/dev/null; then
  log "VM unreachable, skipping"
  exit 0
fi

# Get active tmux sessions on VM
active_sessions=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM" "tmux list-sessions -F '#{session_name}' 2>/dev/null" 2>/dev/null)
if [ -z "$active_sessions" ]; then
  log "no tmux sessions on VM, skipping"
  exit 0
fi

# Get Terminal windows that are connected (have SSH to VM in their name)
connected_sessions=()
reconnected_sessions=()
windows=$(get_windows)

while IFS= read -r line; do
  [ -z "$line" ] && continue
  wid="${line%%|||*}"
  wname="${line#*|||}"

  # Skip non-relevant windows
  echo "$wname" | grep -q "Claude Foundry" && continue
  echo "$wname" | grep -q "caffeinate" && continue

  # Check if this is a disconnected window (shows -zsh or connection closed)
  if echo "$wname" | grep -qE '^\w+ — -zsh|connection closed|Connection .* closed'; then
    # Try to figure out which session this was
    session=$(find_session_for_window "$wid")
    if [ -n "$session" ]; then
      # Verify session still exists on VM
      if echo "$active_sessions" | grep -qx "$session"; then
        log "window $wid disconnected, was $session — reconnecting"
        reconnect_window "$wid" "$session"
        connected_sessions+=("$session")
        reconnected_sessions+=("$session")
      else
        log "window $wid was $session but session no longer exists"
      fi
    else
      log "window $wid disconnected but can't determine session"
    fi
  elif echo "$wname" | grep -q "tmux attach-session -t"; then
    # Extract session name from the SSH command in window title
    sess=$(echo "$wname" | grep -oE 'tmux attach-session -t [a-z0-9-]+' | awk '{print $NF}')
    [ -n "$sess" ] && connected_sessions+=("$sess")
  fi
done <<< "$windows"

# Check if any VM sessions are missing a Terminal window entirely
for session in "${EXPECTED_SESSIONS[@]}"; do
  if echo "$active_sessions" | grep -qx "$session"; then
    found=false
    for cs in "${connected_sessions[@]}"; do
      [ "$cs" = "$session" ] && found=true && break
    done
    if ! $found; then
      log "$session has no Terminal window — opening new one"
      osascript -e "
tell application \"Terminal\"
  do script \"ssh $VM -t 'tmux attach-session -t $session'\"
end tell" 2>/dev/null
      log "opened new window for $session"
    fi
  fi
done

log "check complete: ${#connected_sessions[@]} connected, $(echo "$active_sessions" | wc -l | tr -d ' ') VM sessions"
