#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${DWS_LOG_DIR:-/var/log/dws}"
KEEP_COUNT="${DWS_LOG_RETENTION_WEEKS:-4}"
ROTATE_TIMESTAMP="${DWS_LOG_ROTATE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
DRY_RUN=0

ROTATED_COUNT=0
SKIPPED_COUNT=0
PRUNED_COUNT=0

usage() {
  cat <<'EOF'
usage: dws-rotate-logs.sh [--dry-run] [--dir DIR] [--keep-weeks N]

Rotate regular files in /var/log/dws into timestamped gzip archives and keep
the four most recent archives per log by default.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

log() {
  printf '%s\n' "$*"
}

archive_base() {
  printf '%s\n' "$1" | sed -E 's/\.[0-9]{8}T[0-9]{6}Z\.gz$//'
}

list_active_logs() {
  find "$LOG_DIR" -maxdepth 1 -type f \
    ! -name '.*' \
    ! -name '*.gz' \
    ! -name '*.tmp' \
    ! -name '*.lock' | sort
}

list_archives() {
  find "$LOG_DIR" -maxdepth 1 -type f -name '*.????????T??????Z.gz' | sort -r
}

rotate_log() {
  local path="$1" archive tmp

  if [ ! -s "$path" ]; then
    log "skip empty ${path}"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi

  archive="${path}.${ROTATE_TIMESTAMP}.gz"
  tmp="${archive}.tmp"
  [ ! -e "$archive" ] || die "archive already exists: ${archive}"
  [ ! -e "$tmp" ] || die "temporary archive already exists: ${tmp}"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would rotate ${path} -> ${archive}"
    ROTATED_COUNT=$((ROTATED_COUNT + 1))
    return 0
  fi

  gzip -c -- "$path" >"$tmp"
  mv -- "$tmp" "$archive"
  : >"$path"
  log "rotated ${path} -> ${archive}"
  ROTATED_COUNT=$((ROTATED_COUNT + 1))
}

prune_archives() {
  local archive base count
  declare -A kept=()

  while IFS= read -r archive; do
    base=$(archive_base "$archive")
    count="${kept[$base]:-0}"

    if [ "$count" -lt "$KEEP_COUNT" ]; then
      kept["$base"]=$((count + 1))
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "would prune ${archive}"
    else
      rm -f -- "$archive"
      log "pruned ${archive}"
    fi
    PRUNED_COUNT=$((PRUNED_COUNT + 1))
  done < <(list_archives)
}

main() {
  local path

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --dir)
        [ $# -ge 2 ] || die "--dir requires a path"
        LOG_DIR="$2"
        shift
        ;;
      --dir=*)
        LOG_DIR="${1#*=}"
        ;;
      --keep-weeks|--keep)
        [ $# -ge 2 ] || die "$1 requires a count"
        KEEP_COUNT="$2"
        shift
        ;;
      --keep-weeks=*|--keep=*)
        KEEP_COUNT="${1#*=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown flag: $1"
        ;;
    esac
    shift
  done

  is_uint "$KEEP_COUNT" || die "--keep-weeks must be a non-negative integer"
  [ "$KEEP_COUNT" -ge 1 ] || die "--keep-weeks must be at least 1"
  [[ "$ROTATE_TIMESTAMP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "invalid rotation timestamp: ${ROTATE_TIMESTAMP}"

  mkdir -p -- "$LOG_DIR"

  while IFS= read -r path; do
    rotate_log "$path"
  done < <(list_active_logs)

  prune_archives

  log
  log "Summary"
  log "  rotated: ${ROTATED_COUNT}"
  log "  skipped: ${SKIPPED_COUNT}"
  log "  pruned:  ${PRUNED_COUNT}"
}

main "$@"
