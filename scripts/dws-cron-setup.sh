#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATTERN=' # dws-(health-check|cleanup|sync-all)$'
JOBS=(
  "*/15 * * * * $BASE_DIR/dws-health-check.sh >/dev/null 2>&1 # dws-health-check"
  "0 3 * * 0 $BASE_DIR/dws-cleanup.sh >/dev/null 2>&1 # dws-cleanup"
  "0 6 * * * $BASE_DIR/dws-sync-all.sh >/dev/null 2>&1 # dws-sync-all"
)

current=$(crontab -l 2>/dev/null || true)

if [ "${1:-}" = "--remove" ]; then
  next=$(printf '%s\n' "$current" | grep -Ev "$PATTERN" || true)
  printf '%s\n' "$next" | crontab -
  echo "removed dws cron entries"
  exit 0
fi

next="$current"
for job in "${JOBS[@]}"; do
  printf '%s\n' "$current" | grep -Fqx "$job" || next="${next}${next:+$'\n'}$job"
done

printf '%s\n' "$next" | crontab -
echo "installed dws cron entries:"
printf '  %s\n' "${JOBS[@]}"
