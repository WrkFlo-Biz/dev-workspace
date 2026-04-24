#!/usr/bin/env bash
set -euo pipefail

svc_total=0; svc_ok=0
for u in dws-task-monitor dws-sessions-init; do
  svc_total=$((svc_total + 1))
  systemctl --user is-active "$u" >/dev/null 2>&1 && svc_ok=$((svc_ok + 1))
done

workers=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cE '^(dws-|worker-|orchestrator)' || echo 0)

if [ -f "$HOME/projects/dev-workspace/.state/task-queue.json" ]; then
  pending=$(python3 -c "import json; d=json.load(open('$HOME/projects/dev-workspace/.state/task-queue.json')); print(sum(1 for t in d['tasks'] if t['status']=='pending'))" 2>/dev/null || echo "?")
else
  pending="?"
fi

peers=$(tailscale status 2>/dev/null | grep -c '100\.' || echo 0)
ts_ip=$(tailscale ip -4 2>/dev/null || echo "down")

if [ -f /etc/ssh/sshd_config.d/01-wrkflo-hardening.conf ]; then ssh_status="hardened"; else ssh_status="default"; fi

disk=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
cron_jobs=$(crontab -l 2>/dev/null | grep -c 'dws-' || echo 0)

if [ "${1:-}" = "--json" ]; then
  printf '{"services":"%s/%s","workers":%s,"queue_pending":%s,"tailnet_peers":%s,"tailnet_ip":"%s","ssh":"%s","disk_pct":%s,"cron_jobs":%s}\n' \
    "$svc_ok" "$svc_total" "$workers" "$pending" "$peers" "$ts_ip" "$ssh_status" "$disk" "$cron_jobs"
else
  printf 'services:%s/%s workers:%s queue:%s-pending tailnet:%s-peers(%s) ssh:%s disk:%s%% cron:%s-jobs\n' \
    "$svc_ok" "$svc_total" "$workers" "$pending" "$peers" "$ts_ip" "$ssh_status" "$disk" "$cron_jobs"
fi
