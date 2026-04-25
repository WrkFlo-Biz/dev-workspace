#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2012
set -euo pipefail

# dws-orchestrator-boot.sh — One-command bootstrap for the dev workspace.
# SSH in, run this, walk away. The orchestrator monitors and feeds workers.
#
# Usage:
#   dws-orchestrator-boot.sh              # 2 workers (default)
#   dws-orchestrator-boot.sh 4            # 4 workers
#   dws-orchestrator-boot.sh 0            # orchestrator only, no workers

WORKER_COUNT="${1:-2}"
SESSION_NAME="orchestrator"
FOUNDRY_ENV="$HOME/.config/wrkflo/foundry.env"
PROJECTS_DIR="$HOME/projects"
LOG="/tmp/orchestrator-log.txt"
PROMPT_FILE="/tmp/orchestrator-prompt.txt"

green() { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

green "=== Dev Workspace Orchestrator Boot ==="
echo "Workers: $WORKER_COUNT | Projects: $(ls "$PROJECTS_DIR" | wc -l | tr -d ' ')"

[ -f "$FOUNDRY_ENV" ] && source "$FOUNDRY_ENV" && green "Foundry config loaded"

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
DISK_PCT=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
MEM_AVAIL=$(free -h 2>/dev/null | awk '/Mem:/{print $7}' || echo "unknown")
REPOS=$(ls "$PROJECTS_DIR" | tr '\n' ', ' | sed 's/,$//')
SERVICES=$(systemctl --user list-units --type=service --state=active 2>/dev/null | grep -cE 'dws|wrkflo' || echo 0)
CRON_JOBS=$(crontab -l 2>/dev/null | grep -c 'dws-' || echo 0)

echo "Tailscale: $TAILSCALE_IP | Disk: ${DISK_PCT}% | Mem free: $MEM_AVAIL"
echo "Services: $SERVICES active | Cron: $CRON_JOBS jobs | Repos: $REPOS"

# Kill existing orchestrator
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    yellow "Replacing existing orchestrator"
    tmux kill-session -t "$SESSION_NAME"
fi

# Start workers
for i in $(seq 1 "$WORKER_COUNT"); do
    WORKER="worker-$i"
    if tmux has-session -t "$WORKER" 2>/dev/null; then
        yellow "$WORKER: already running"
    else
        tmux new-session -d -s "$WORKER" \
            "source $FOUNDRY_ENV 2>/dev/null; cd $PROJECTS_DIR/dev-workspace; exec codex --full-auto"
        green "$WORKER: started"
        sleep 2
    fi
done

# Discover active workers
WORKERS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v "$SESSION_NAME" | tr '\n' ', ' | sed 's/,$//')

# Load handoff from previous session
HANDOFF_FILE="$PROJECTS_DIR/dev-workspace/.state/orchestrator-handoff.md"
HANDOFF_CONTEXT=""
if [ -f "$HANDOFF_FILE" ]; then
    HANDOFF_CONTEXT=$(cat "$HANDOFF_FILE")
    green "Loaded handoff from previous session"
fi

WORKLOAD_FILE="$PROJECTS_DIR/dev-workspace/.state/terminal-workload.md"
WORKLOAD_CONTEXT=""
if [ -f "$WORKLOAD_FILE" ]; then
    WORKLOAD_CONTEXT=$(cat "$WORKLOAD_FILE")
    green "Loaded live workload"
fi

# Build orchestrator prompt
cat > "$PROMPT_FILE" << ORCHESTRATOR_PROMPT
You are the ORCHESTRATOR for this dev workspace VM. You do not write code. You monitor and manage worker Codex sessions.

SYSTEM: dev-workspace-vm ($TAILSCALE_IP) | Disk: ${DISK_PCT}% | Mem: $MEM_AVAIL free
REPOS: $REPOS
SERVICES: $SERVICES active | CRON: $CRON_JOBS jobs
TAILNET: dev-workspace-vm, mosess-macbook-air-3, iphone-15-pro-max, openclaw-gateway-vm
CLI: az, gh, codex, tailscale, ufw (all authenticated)

PROJECTS:
- dev-workspace: ops scripts, tests, CI, systemd, monitoring (main focus)
- wrkflo-orchestrator: Python control plane, worker modules, state DB, dashboard API
- global-sentinel: trading sentinel, approval system, telegram bot
- wrkflo-voice-agents-ops: voice agent docs, Twilio/ElevenLabs
- openclaw-prod: legal AI platform
- global-sentinel-azure-quantum: quantum extensions

ACTIVE WORKERS: $WORKERS

YOUR LOOP (run continuously, every 60 seconds):
1. Scan each worker: tmux capture-pane -pt WORKER -S -15
2. Determine state:
   - "Working" or "Waiting for agents" = leave alone
   - "Booting MCP server" >60s = tmux send-keys -t WORKER Escape
   - Edit approval prompt = tmux send-keys -t WORKER y Enter
   - Idle at Codex prompt = assign next task from backlog
3. After EVERY send-keys: wait 5s, capture-pane again, verify "Working" appears
4. If not "Working" after send-keys, press Enter and check again
5. Log each cycle to $LOG with timestamp

	LIVE WORKLOAD (primary source of truth for current assignments, standby state, and commit boundaries):
	$WORKLOAD_CONTEXT

	FALLBACK BACKLOG (use only if the workload file leaves an idle worker unassigned):
	- Run full test suite and fix failures
	- Shellcheck scripts/ and fix warnings
	- Update docs/ to match current architecture
	- Clean stale .state/ files
	- Fix bin/ wrapper inconsistencies
	- Consolidate CI workflows
	- Remove deprecated task-monitor refs from systemd configs

	RULES:
	- Never assign same file to two workers
	- One repo per worker at a time
	- ALWAYS use ~/bin/tmux-send to dispatch tasks (never raw tmux send-keys). It auto-presses Enter and verifies.
	- Read /tmp/agent-coordination.md for short progress notes
	- Read $WORKLOAD_FILE before assigning or reassigning any worker
	- Update $WORKLOAD_FILE before you send a worker onto a new lane

	PREVIOUS SESSION HANDOFF (longer-lived repo context and boundaries):
	$HANDOFF_CONTEXT

	Start by reading the live workload above. If it conflicts with older pane text or the fallback backlog, the workload file wins.
	Then read the handoff above for broader repo context.
	Then begin your monitoring scan.
ORCHESTRATOR_PROMPT

green "Prompt ready ($(wc -c < "$PROMPT_FILE" | tr -d ' ') bytes)"

# Start orchestrator
tmux new-session -d -s "$SESSION_NAME" \
    "source $FOUNDRY_ENV 2>/dev/null; cd $PROJECTS_DIR/dev-workspace; exec codex --full-auto"
green "Orchestrator session created"
sleep 6

# Send prompt using tmux-send (auto-Enter + verify)
PROMPT_TEXT=$(cat "$PROMPT_FILE")
tmux-send "$SESSION_NAME" "$PROMPT_TEXT" && green "Orchestrator is RUNNING" || yellow "Prompt submitted — verify: tmux attach -t orchestrator"

echo ""
green "=== Boot complete ==="
echo "  Attach:  tmux attach -t orchestrator"
echo "  Workers: $WORKERS"
echo "  Log:     tail -f $LOG"
echo "  Connect: ssh moses@$TAILSCALE_IP"
