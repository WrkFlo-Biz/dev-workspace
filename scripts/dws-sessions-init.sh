#!/usr/bin/env bash
# dws-sessions-init.sh — create all expected tmux sessions on boot
set -o pipefail

SESSIONS=(dws-a dws-b worker-c worker-d worker-e worker-f worker-g worker-h worker-i orchestrator)
REPO="dev-workspace"
CODEX_CMD="codex --profile foundry-5_4 --search --dangerously-bypass-approvals-and-sandbox"

log() { printf '%s [sessions-init] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Wait for tmux server
for i in {1..10}; do
  tmux start-server 2>/dev/null && break
  sleep 1
done

ORCH_CONTEXT="$HOME/projects/dev-workspace/.state/orchestrator-context.md"

for session in "${SESSIONS[@]}"; do
  if tmux has-session -t "$session" 2>/dev/null; then
    log "$session: already exists, skipping"
    continue
  fi

  if [ "$session" = "orchestrator" ]; then
    # Orchestrator starts in home with access to all projects
    tmux new-session -d -s "$session"       "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects; exec $CODEX_CMD\""
    log "$session: created (orchestrator — multi-project)"
  else
    # Workers start in dev-workspace by default; orchestrator reassigns as needed
    tmux new-session -d -s "$session"       "bash --norc -c \"source ~/.config/wrkflo/foundry.env 2>/dev/null; cd ~/projects/$REPO; exec $CODEX_CMD\""
    log "$session: created (worker — default repo: $REPO)"
  fi
  sleep 2
done

log "sessions init complete: ${#SESSIONS[@]} sessions"
