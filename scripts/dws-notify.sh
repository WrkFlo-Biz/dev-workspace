#!/usr/bin/env bash
set -euo pipefail
A=/tmp/dws-alerts.txt
S=/tmp/dws-alerts.read
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
count(){ [ -f "$A" ] && wc -l < "$A" || echo 0; }
usage(){ printf 'usage: %s {alert "message"|check|clear}\n' "$(basename "$0")"; }

case "${1:-}" in
  alert) shift; [ $# -gt 0 ] || { usage >&2; exit 1; }; printf '%s %s\n' "$(ts)" "$*" >> "$A" ;;
  check)
    total=$(count); last=$(cat "$S" 2>/dev/null || echo 0)
    [ "$total" -gt "$last" ] && sed -n "$((last + 1)),$total p" "$A" || echo "no unread alerts"
    printf '%s\n' "$total" > "$S"
    ;;
  clear) count > "$S" ;;
  *) usage; exit 1 ;;
esac
