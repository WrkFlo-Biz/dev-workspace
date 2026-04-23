#!/usr/bin/env bash
set -euo pipefail
H=/tmp/dws-health.log
A=/tmp/dws-health-alerts.log
S=/tmp/global-sentinel-sync.out.log
M=/tmp/mac-bridges.out.log
R=$'\033[31m'; G=$'\033[32m'; D=$'\033[2m'; C=$'\033[36m'; N=$'\033[0m'

usage(){ printf 'usage: %s {tail|alerts|health}\n' "$(basename "$0")"; }

paint(){ awk -v r="$R" -v g="$G" -v d="$D" -v c="$C" -v n="$N" '
/^==> .* <==$/ { sub(/^==> /,""); sub(/ <==$/,""); print c "[" $0 "]" n; next }
{
  line=$0
  sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/, d "&" n, line)
  gsub(/ALERT/, r "&" n, line)
  gsub(/ok/, g "&" n, line)
  print line
}'; }

tail_all(){ tail -n "${LINES:-40}" -F "$H" "$A" "$S" "$M" 2>&1 | paint; }

show_alerts(){
  local cut
  cut=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S')
  [ -f "$A" ] || { echo "missing $A"; exit 0; }
  awk -v cut="$cut" '{
    ts=substr($0,1,19); dated=(substr($0,5,1)=="-" && substr($0,8,1)=="-")
    if (index($0,"ALERT") && (!dated || ts >= cut)) print
  }' "$A" | paint
}

show_health(){ [ -f "$H" ] || { echo "missing $H"; exit 0; }; tail -n "${LINES:-80}" "$H" | paint; }

case "${1:-}" in
  tail) tail_all ;;
  alerts) show_alerts ;;
  health) show_health ;;
  -h|--help|help|'') usage ;;
  *) usage; exit 1 ;;
esac
