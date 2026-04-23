#!/usr/bin/env bash
set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$BASE_DIR/dws-env.sh"

warn_pct() {
  local n=${1:-0}
  if [ "$n" -ge 90 ]; then red "${n}%"; elif [ "$n" -ge 80 ]; then yellow "${n}%"; else green "${n}%"; fi
}

disk_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5+0}')
mem_pct=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')

printf '%s %s\n' "$(bold 'Dev Workspace')" "$(dim "$(date '+%Y-%m-%d %H:%M:%S %Z')")"
printf '  host: %s  vm: %s  mac: %s\n' "$(green "$(hostname -s 2>/dev/null || hostname)")" "100.117.16.63" "${MAC_GUI_URL#http://}"

echo
printf '%s\n' "$(bold 'Orchestrator')"
"$BASE_DIR/dws-launcher.sh" status --motd 2>/dev/null || true

echo
printf '%s\n' "$(bold 'Active tmux sessions')"
if tmux ls >/dev/null 2>&1; then
  tmux ls -F '  #{session_name}  #{?session_attached,attached,detached}  #{session_windows}w'
else
  printf '  %s\n' "$(dim 'none')"
fi

echo
printf '%s\n' "$(bold 'Health alerts')"
if [ -s /tmp/dws-health-alerts.log ]; then
  tail -5 /tmp/dws-health-alerts.log | sed 's/^/  /'
else
  printf '  %s\n' "$(green 'none')"
fi

echo
printf '%s\n' "$(bold 'Warnings')"
printf '  disk /: %s\n' "$(warn_pct "$disk_pct")"
printf '  mem:    %s\n' "$(warn_pct "$mem_pct")"
