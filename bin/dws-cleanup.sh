#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

TMP_ROOT="${DWS_TMPDIR:-/tmp}"
REPO_ROOT="${DWS_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"
SESSION_HOURS=24
COMPRESS_LOG_DAYS=1
LOG_DAYS=7
TEMP_DAYS=3
DRY=0

WORKTREE_REMOVED=0
TMUX_REMOVED=0
LOG_COMPRESSED=0
LOG_REMOVED=0
TEMP_REMOVED=0

usage() {
  cat <<'EOF'
usage: dws-cleanup.sh [--dry-run] [--repo-root DIR] [--session-hours N] [--compress-log-days N] [--log-days N] [--temp-days N] [--tmp-dir DIR]
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

tmux_ctl() {
  if [ -n "$TMUX_SOCKET" ]; then
    tmux -L "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

bump() {
  case "$1" in
    WORKTREE_REMOVED) WORKTREE_REMOVED=$((WORKTREE_REMOVED + 1)) ;;
    TMUX_REMOVED) TMUX_REMOVED=$((TMUX_REMOVED + 1)) ;;
    LOG_COMPRESSED) LOG_COMPRESSED=$((LOG_COMPRESSED + 1)) ;;
    LOG_REMOVED) LOG_REMOVED=$((LOG_REMOVED + 1)) ;;
    TEMP_REMOVED) TEMP_REMOVED=$((TEMP_REMOVED + 1)) ;;
  esac
}

find_matches() {
  local age="$1"
  shift
  local pat

  for pat in "$@"; do
    find "$TMP_ROOT" -maxdepth 1 -type f -name "$pat" -mmin "+$age" -print
  done | sort -u
}

remove_file() {
  local kind="$1" path="$2" key="$3"

  if [ "$DRY" -eq 1 ]; then
    printf 'would remove %-8s %s\n' "$kind" "$path"
  else
    rm -f -- "$path"
    printf 'removed %-8s %s\n' "$kind" "$path"
  fi
  bump "$key"
}

remove_session() {
  local name="$1"

  if [ "$DRY" -eq 1 ]; then
    printf 'would remove %-8s %s\n' session "$name"
  else
    tmux_ctl kill-session -t "$name" >/dev/null 2>&1 || return 0
    printf 'removed %-8s %s\n' session "$name"
  fi
  bump TMUX_REMOVED
}

compress_log() {
  local path="$1"

  if [ "$DRY" -eq 1 ]; then
    printf 'would compress %-6s %s\n' log "$path"
  else
    gzip -f -- "$path"
    printf 'compressed %-6s %s.gz\n' log "$path"
  fi
  bump LOG_COMPRESSED
}

ensure_repo_root() {
  if git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT=$(git -C "$REPO_ROOT" rev-parse --show-toplevel)
    return 0
  fi

  if git -C "$DEFAULT_REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT=$(git -C "$DEFAULT_REPO_ROOT" rev-parse --show-toplevel)
    return 0
  fi

  die "repo root not found or not a git repo: $REPO_ROOT"
}

worktree_ref_missing() {
  local branch_ref="$1"
  [ -n "$branch_ref" ] || return 1
  git -C "$REPO_ROOT" show-ref --verify --quiet "$branch_ref" && return 1
  return 0
}

remove_worktree() {
  local path="$1" branch_ref="$2"

  if [ "$DRY" -eq 1 ]; then
    printf 'would remove %-8s %s (%s missing)\n' worktree "$path" "$branch_ref"
    bump WORKTREE_REMOVED
    return 0
  fi

  if [ -e "$path" ] || [ -L "$path" ]; then
    git -C "$REPO_ROOT" worktree remove --force -- "$path" >/dev/null 2>&1 || return 0
  else
    git -C "$REPO_ROOT" worktree prune --expire now >/dev/null 2>&1 || return 0
  fi

  printf 'removed %-8s %s (%s missing)\n' worktree "$path" "$branch_ref"
  bump WORKTREE_REMOVED
}

flush_worktree_block() {
  local repo_top="$1" path="$2" branch_ref="$3"

  [ -n "$path" ] || return 0
  [ "$path" != "$repo_top" ] || return 0
  worktree_ref_missing "$branch_ref" || return 0
  remove_worktree "$path" "$branch_ref"
}

cleanup_worktrees() {
  local repo_top line path="" branch_ref=""

  command -v git >/dev/null 2>&1 || return 0
  repo_top=$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$repo_top" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *)
        flush_worktree_block "$repo_top" "$path" "$branch_ref"
        path=${line#worktree }
        branch_ref=""
        ;;
      branch\ *)
        branch_ref=${line#branch }
        ;;
      '')
        ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)

  flush_worktree_block "$repo_top" "$path" "$branch_ref"
}

session_shows_working() {
  local session="$1" title pane_capture

  title=$(tmux_ctl list-panes -t "$session" -F '#{pane_title}' 2>/dev/null | sed -n '1p')
  if printf '%s\n' "$title" | grep -Eiq '(^|[^[:alpha:]])working([^[:alpha:]]|$)'; then
    return 0
  fi

  # Codex/Claude often expose active work via a spinner-prefixed pane title.
  if printf '%s\n' "$title" | grep -Eq '^[^ -~]+[[:space:]]'; then
    return 0
  fi

  pane_capture=$(tmux_ctl capture-pane -p -t "${session}:0.0" -S -120 2>/dev/null || true)
  printf '%s\n' "$pane_capture" | grep -Eiq '(^|[^[:alpha:]])working([^[:alpha:]]|$)'
}

cleanup_sessions() {
  local now name attached created last recent

  command -v tmux >/dev/null 2>&1 || return 0
  now=$(date +%s)

  while IFS='|' read -r name attached created last; do
    [ -n "${name:-}" ] || continue
    is_int "${attached:-}" || continue
    is_int "${created:-}" || continue
    [ "$attached" -eq 0 ] || continue

    recent=$created
    if is_int "${last:-}" && [ "$last" -gt "$recent" ]; then
      recent=$last
    fi

    [ $((now - recent)) -ge $((SESSION_HOURS * 3600)) ] || continue
    session_shows_working "$name" && continue
    remove_session "$name"
  done < <(tmux_ctl list-sessions -F '#{session_name}|#{session_attached}|#{session_created}|#{session_last_attached}' 2>/dev/null || true)
}

cleanup_logs() {
  local -a files=()

  command -v gzip >/dev/null 2>&1 || return 0

  mapfile -t files < <(find_matches "$((COMPRESS_LOG_DAYS * 1440))" \
    'dws-*.log' 'socat-*.log' 'mac-bridges.out.log')
  local path
  for path in "${files[@]}"; do
    compress_log "$path"
  done

  mapfile -t files < <(find_matches "$((LOG_DAYS * 1440))" \
    'dws-*.log' 'dws-*.log.gz' 'socat-*.log' 'socat-*.log.gz' 'mac-bridges.out.log' 'mac-bridges.out.log.gz')
  for path in "${files[@]}"; do
    remove_file log "$path" LOG_REMOVED
  done
}

cleanup_temp_files() {
  local -a files=()
  local path

  mapfile -t files < <(find_matches "$((TEMP_DAYS * 1440))" \
    'dws-backup-manifest.txt' \
    'dws-backup-restore-test.txt' \
    'dws-test-*.txt' \
    'dws-quick-*.out' \
    'dws-launcher-*.sh' \
    'mac-screen.png' \
    'mac-chrome-example.png')

  for path in "${files[@]}"; do
    remove_file temp "$path" TEMP_REMOVED
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repo-root) shift; REPO_ROOT="${1:-}" ;;
    --session-hours) shift; SESSION_HOURS="${1:-}" ;;
    --compress-log-days) shift; COMPRESS_LOG_DAYS="${1:-}" ;;
    --log-days) shift; LOG_DAYS="${1:-}" ;;
    --temp-days) shift; TEMP_DAYS="${1:-}" ;;
    --tmp-dir) shift; TMP_ROOT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown flag: $1" ;;
  esac
  shift
done

is_int "$SESSION_HOURS" || die "--session-hours must be an integer"
is_int "$COMPRESS_LOG_DAYS" || die "--compress-log-days must be an integer"
is_int "$LOG_DAYS" || die "--log-days must be an integer"
is_int "$TEMP_DAYS" || die "--temp-days must be an integer"
[ -d "$TMP_ROOT" ] || die "tmp dir not found: $TMP_ROOT"
ensure_repo_root

cleanup_worktrees
cleanup_sessions
cleanup_logs
cleanup_temp_files

printf '\nSummary (%s)\n' "$([ "$DRY" -eq 1 ] && echo dry-run || echo apply)"
printf '  stale worktrees: %d\n' "$WORKTREE_REMOVED"
printf '  tmux sessions:   %d\n' "$TMUX_REMOVED"
printf '  logs compressed: %d\n' "$LOG_COMPRESSED"
printf '  stale logs:      %d\n' "$LOG_REMOVED"
printf '  temp files:      %d\n' "$TEMP_REMOVED"
