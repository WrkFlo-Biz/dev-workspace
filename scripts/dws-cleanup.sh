#!/usr/bin/env bash
set -euo pipefail

TMP_ROOT="${DWS_TMPDIR:-/tmp}"
TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"
SESSION_HOURS=24
LOG_DAYS=7
TEMP_DAYS=3
DRY=0
TMUX_REMOVED=0
LOG_REMOVED=0
TEMP_REMOVED=0

usage() {
  cat <<'EOF'
usage: dws-cleanup.sh [--dry-run] [--session-hours N] [--log-days N] [--temp-days N] [--tmp-dir DIR]
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }
is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
tmux_ctl() {
  if [ -n "$TMUX_SOCKET" ]; then
    tmux -L "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}
bump() {
  case "$1" in
    TMUX_REMOVED) TMUX_REMOVED=$((TMUX_REMOVED + 1)) ;;
    LOG_REMOVED) LOG_REMOVED=$((LOG_REMOVED + 1)) ;;
    TEMP_REMOVED) TEMP_REMOVED=$((TEMP_REMOVED + 1)) ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --session-hours) shift; SESSION_HOURS="${1:-}" ;;
    --log-days) shift; LOG_DAYS="${1:-}" ;;
    --temp-days) shift; TEMP_DAYS="${1:-}" ;;
    --tmp-dir) shift; TMP_ROOT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown flag: $1" ;;
  esac
  shift
done

is_int "$SESSION_HOURS" || die "--session-hours must be an integer"
is_int "$LOG_DAYS" || die "--log-days must be an integer"
is_int "$TEMP_DAYS" || die "--temp-days must be an integer"
[ -d "$TMP_ROOT" ] || die "tmp dir not found: $TMP_ROOT"

act() {
  local kind="$1" path="$2" key="$3"
  if [ "$DRY" -eq 1 ]; then
    printf 'would remove %-7s %s\n' "$kind" "$path"
  elif [ "$kind" = "session" ]; then
    tmux_ctl kill-session -t "$path" >/dev/null 2>&1 || return 0
    printf 'removed %-7s %s\n' "$kind" "$path"
  else
    rm -f -- "$path"
    printf 'removed %-7s %s\n' "$kind" "$path"
  fi
  bump "$key"
}

cleanup_sessions() {
  local now name attached created last recent
  command -v tmux >/dev/null 2>&1 || return 0
  now=$(date +%s)
  while IFS='|' read -r name attached created last; do
    [ -n "${name:-}" ] || continue
    [ "${attached:-0}" -eq 0 ] || continue
    recent=$created; [ "${last:-0}" -gt "$recent" ] && recent=$last
    [ $((now - recent)) -lt $((SESSION_HOURS * 3600)) ] || act session "$name" TMUX_REMOVED
  done < <(tmux_ctl list-sessions -F '#{session_name}|#{session_attached}|#{session_created}|#{session_last_attached}' 2>/dev/null || true)
}

cleanup_files() {
  local kind="$1" age="$2" key="$3"; shift 3
  local -a files=()
  mapfile -t files < <(for pat in "$@"; do find "$TMP_ROOT" -maxdepth 1 -type f -name "$pat" -mmin "+$age" -print; done | sort -u)
  for path in "${files[@]}"; do act "$kind" "$path" "$key"; done
}

cleanup_sessions
cleanup_files log  "$((LOG_DAYS * 1440))"  LOG_REMOVED  \
  dws-health.log dws-health-alerts.log dws-sync-all.out.log mac-bridges.out.log 'socat-*.log'
cleanup_files temp "$((TEMP_DAYS * 1440))" TEMP_REMOVED \
  dws-backup-manifest.txt dws-backup-restore-test.txt 'dws-test-*.txt' 'dws-quick-*.out' 'dws-launcher-*.sh' mac-screen.png mac-chrome-example.png

printf '\nSummary (%s)\n' "$([ "$DRY" -eq 1 ] && echo dry-run || echo apply)"
printf '  tmux sessions: %d\n' "$TMUX_REMOVED"
printf '  stale logs:    %d\n' "$LOG_REMOVED"
printf '  temp files:    %d\n' "$TEMP_REMOVED"
