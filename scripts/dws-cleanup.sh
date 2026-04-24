#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

TMP_ROOT="${DWS_TMPDIR:-/tmp}"
REPO_ROOT="${DWS_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-${HOME}/projects}"
TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"
CLEANUP_STAMP_PATH="${DWS_CLEANUP_STAMP_PATH:-${TMP_ROOT}/dws-cleanup.last-success}"
PIP_CACHE_DIR="${DWS_PIP_CACHE_DIR:-}"
APT_CACHE_DIR="${DWS_APT_CACHE_DIR:-/var/cache/apt/archives}"
SESSION_HOURS=24
COMPRESS_LOG_DAYS=2
LOG_DAYS=7
TEMP_DAYS=3
DRY=0

WORKTREE_REMOVED=0
WORKTREE_PRUNED=0
TMUX_REMOVED=0
LOG_COMPRESSED=0
LOG_REMOVED=0
TEMP_REMOVED=0
PIP_CACHE_CLEANED=0
APT_CACHE_CLEANED=0
BYTES_RECOVERED=0

ROOT_ACCESS=-1
ROOT_PREFIX=()

usage() {
  cat <<'EOF'
usage: dws-cleanup.sh [--dry-run] [--repo-root DIR] [--projects-root DIR] [--session-hours N] [--compress-log-days N] [--log-days N] [--temp-days N] [--tmp-dir DIR]
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
    WORKTREE_PRUNED) WORKTREE_PRUNED=$((WORKTREE_PRUNED + 1)) ;;
    TMUX_REMOVED) TMUX_REMOVED=$((TMUX_REMOVED + 1)) ;;
    LOG_COMPRESSED) LOG_COMPRESSED=$((LOG_COMPRESSED + 1)) ;;
    LOG_REMOVED) LOG_REMOVED=$((LOG_REMOVED + 1)) ;;
    TEMP_REMOVED) TEMP_REMOVED=$((TEMP_REMOVED + 1)) ;;
    PIP_CACHE_CLEANED) PIP_CACHE_CLEANED=$((PIP_CACHE_CLEANED + 1)) ;;
    APT_CACHE_CLEANED) APT_CACHE_CLEANED=$((APT_CACHE_CLEANED + 1)) ;;
  esac
}

init_root_access() {
  if [ "$ROOT_ACCESS" -ne -1 ]; then
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    ROOT_ACCESS=1
    ROOT_PREFIX=()
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    ROOT_ACCESS=1
    ROOT_PREFIX=(sudo -n)
    return 0
  fi

  ROOT_ACCESS=0
}

have_root_access() {
  init_root_access
  [ "$ROOT_ACCESS" -eq 1 ]
}

run_root() {
  have_root_access || return 1
  if [ "${#ROOT_PREFIX[@]}" -eq 0 ]; then
    "$@"
  else
    "${ROOT_PREFIX[@]}" "$@"
  fi
}

path_size_bytes() {
  local path="$1"
  local use_root="${2:-0}"
  local output=""

  [ -e "$path" ] || [ -L "$path" ] || {
    printf '0\n'
    return 0
  }

  if [ "$use_root" -eq 1 ]; then
    output="$(run_root du -sb -- "$path" 2>/dev/null || true)"
  else
    output="$(du -sb -- "$path" 2>/dev/null || true)"
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output" | awk 'NR == 1 { print $1; exit }'
  else
    printf '0\n'
  fi
}

add_recovered_bytes() {
  local bytes="${1:-0}"
  is_int "$bytes" || return 0
  [ "$bytes" -gt 0 ] || return 0
  BYTES_RECOVERED=$((BYTES_RECOVERED + bytes))
}

format_bytes() {
  local bytes="${1:-0}"

  awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB PiB", units, " ")
      idx = 1
      while (bytes >= 1024 && idx < 6) {
        bytes /= 1024
        idx++
      }
      if (idx == 1) {
        printf "%d %s", bytes, units[idx]
      } else {
        printf "%.1f %s", bytes, units[idx]
      }
    }
  '
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
  local size_before

  size_before="$(path_size_bytes "$path")"
  if [ "$DRY" -eq 1 ]; then
    printf 'would remove %-8s %s\n' "$kind" "$path"
  else
    rm -f -- "$path"
    printf 'removed %-8s %s\n' "$kind" "$path"
  fi
  add_recovered_bytes "$size_before"
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
  local size_before size_after size_delta

  size_before="$(path_size_bytes "$path")"
  if [ "$DRY" -eq 1 ]; then
    printf 'would compress %-6s %s\n' log "$path"
    add_recovered_bytes "$size_before"
  else
    gzip -f -- "$path"
    printf 'compressed %-6s %s.gz\n' log "$path"
    size_after="$(path_size_bytes "${path}.gz")"
    size_delta=$((size_before - size_after))
    add_recovered_bytes "$size_delta"
  fi
  bump LOG_COMPRESSED
}

write_success_stamp() {
  if [ "$DRY" -eq 1 ]; then
    printf 'would write %-8s %s\n' stamp "$CLEANUP_STAMP_PATH"
    return 0
  fi

  mkdir -p -- "$(dirname "$CLEANUP_STAMP_PATH")"
  cat >"$CLEANUP_STAMP_PATH" <<EOF
completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
host=$(hostname -s 2>/dev/null || hostname)
repo_root=${REPO_ROOT}
projects_root=${PROJECTS_ROOT}
tmp_root=${TMP_ROOT}
session_hours=${SESSION_HOURS}
compress_log_days=${COMPRESS_LOG_DAYS}
log_days=${LOG_DAYS}
temp_days=${TEMP_DAYS}
EOF
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

list_repo_roots() {
  local repo repo_top

  {
    printf '%s\n' "$REPO_ROOT"

    if [ -d "$PROJECTS_ROOT" ]; then
      for repo in "$PROJECTS_ROOT"/*; do
        [ -d "$repo" ] || continue
        repo_top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
        [ -n "$repo_top" ] || continue
        printf '%s\n' "$repo_top"
      done
    fi
  } | sort -u
}

worktree_ref_missing() {
  local repo_root="$1" branch_ref="$2"
  [ -n "$branch_ref" ] || return 1
  git -C "$repo_root" show-ref --verify --quiet "$branch_ref" && return 1
  return 0
}

remove_worktree() {
  local repo_root="$1" path="$2" branch_ref="$3"
  local size_before

  size_before="$(path_size_bytes "$path")"

  if [ "$DRY" -eq 1 ]; then
    printf 'would remove %-8s %s (%s missing)\n' worktree "$path" "$branch_ref"
    add_recovered_bytes "$size_before"
    bump WORKTREE_REMOVED
    return 0
  fi

  if [ -e "$path" ] || [ -L "$path" ]; then
    git -C "$repo_root" worktree remove --force -- "$path" >/dev/null 2>&1 || return 0
  else
    git -C "$repo_root" worktree prune --expire now >/dev/null 2>&1 || return 0
  fi

  printf 'removed %-8s %s (%s missing)\n' worktree "$path" "$branch_ref"
  add_recovered_bytes "$size_before"
  bump WORKTREE_REMOVED
}

flush_worktree_block() {
  local repo_top="$1" path="$2" branch_ref="$3"

  [ -n "$path" ] || return 0
  [ "$path" != "$repo_top" ] || return 0
  worktree_ref_missing "$repo_top" "$branch_ref" || return 0
  remove_worktree "$repo_top" "$path" "$branch_ref"
}

cleanup_repo_worktrees() {
  local repo_top="$1"
  local line path="" branch_ref=""

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
  done < <(git -C "$repo_top" worktree list --porcelain 2>/dev/null || true)

  flush_worktree_block "$repo_top" "$path" "$branch_ref"
}

cleanup_worktrees() {
  local repo_top

  command -v git >/dev/null 2>&1 || return 0
  while IFS= read -r repo_top; do
    [ -n "$repo_top" ] || continue
    cleanup_repo_worktrees "$repo_top"
  done < <(list_repo_roots)
}

prune_repo_worktrees() {
  local repo="$1" line

  if [ "$DRY" -eq 1 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf 'would prune %-8s %s: %s\n' worktree "$repo" "$line"
      bump WORKTREE_PRUNED
    done < <(git -C "$repo" worktree prune --dry-run --verbose --expire now 2>&1 || true)
  else
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf 'pruned %-8s %s: %s\n' worktree "$repo" "$line"
      bump WORKTREE_PRUNED
    done < <(git -C "$repo" worktree prune --verbose --expire now 2>&1 || true)
  fi
}

prune_project_worktrees() {
  local repo_top

  command -v git >/dev/null 2>&1 || return 0
  while IFS= read -r repo_top; do
    [ -n "$repo_top" ] || continue
    prune_repo_worktrees "$repo_top"
  done < <(list_repo_roots)
}

session_is_dead() {
  local session="$1" pane pane_dead pane_count=0

  while IFS='|' read -r pane pane_dead; do
    [ -n "$pane" ] || continue
    pane_count=$((pane_count + 1))
    [ "${pane_dead:-0}" = "1" ] || return 1
  done < <(tmux_ctl list-panes -t "$session" -F '#{pane_id}|#{pane_dead}' 2>/dev/null || true)

  [ "$pane_count" -eq 0 ] && return 0
  return 0
}

session_has_pane_content() {
  local session="$1" pane pane_capture

  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    pane_capture=$(tmux_ctl capture-pane -p -t "$pane" -S -120 2>/dev/null || true)
    if printf '%s\n' "$pane_capture" | grep -q '[^[:space:]]'; then
      return 0
    fi
  done < <(tmux_ctl list-panes -t "$session" -F '#{pane_id}' 2>/dev/null || true)

  return 1
}

session_shows_working() {
  local session="$1" pane title pane_capture

  while IFS='|' read -r pane title; do
    [ -n "$pane" ] || continue

    if printf '%s\n' "$title" | grep -Eiq '(^|[^[:alpha:]])working([^[:alpha:]]|$)'; then
      return 0
    fi

    # Codex/Claude often expose active work via a spinner-prefixed pane title.
    if printf '%s\n' "$title" | grep -Eq '^[^ -~]+[[:space:]]'; then
      return 0
    fi

    pane_capture=$(tmux_ctl capture-pane -p -t "$pane" -S -120 2>/dev/null || true)
    if printf '%s\n' "$pane_capture" | grep -Eiq '(^|[^[:alpha:]])working([^[:alpha:]]|$)'; then
      return 0
    fi
  done < <(tmux_ctl list-panes -t "$session" -F '#{pane_id}|#{pane_title}' 2>/dev/null || true)

  return 1
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
    session_is_dead "$name" && {
      remove_session "$name"
      continue
    }
    session_has_pane_content "$name" || {
      remove_session "$name"
      continue
    }

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

resolve_pip_cache_dir() {
  if [ -n "$PIP_CACHE_DIR" ]; then
    printf '%s\n' "$PIP_CACHE_DIR"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    PIP_CACHE_DIR="$(python3 -m pip cache dir 2>/dev/null | sed -n '1p' || true)"
  fi

  if [ -z "$PIP_CACHE_DIR" ] && command -v pip >/dev/null 2>&1; then
    PIP_CACHE_DIR="$(pip cache dir 2>/dev/null | sed -n '1p' || true)"
  fi

  if [ -z "$PIP_CACHE_DIR" ]; then
    PIP_CACHE_DIR="${HOME}/.cache/pip"
  fi

  printf '%s\n' "$PIP_CACHE_DIR"
}

cleanup_pip_cache() {
  local cache_dir before after delta

  cache_dir="$(resolve_pip_cache_dir)"
  [ -d "$cache_dir" ] || return 0

  before="$(path_size_bytes "$cache_dir")"
  [ "$before" -gt 0 ] || return 0

  if [ "$DRY" -eq 1 ]; then
    printf 'would clean %-8s %s\n' pip-cache "$cache_dir"
    add_recovered_bytes "$before"
    bump PIP_CACHE_CLEANED
    return 0
  fi

  find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || return 0
  after="$(path_size_bytes "$cache_dir")"
  delta=$((before - after))
  add_recovered_bytes "$delta"

  printf 'cleaned %-8s %s\n' pip-cache "$cache_dir"
  bump PIP_CACHE_CLEANED
}

apt_cache_needs_root() {
  case "$APT_CACHE_DIR" in
    /var/cache/apt/*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_apt_cache() {
  local use_root=0
  local before after delta

  [ -d "$APT_CACHE_DIR" ] || return 0

  if apt_cache_needs_root; then
    use_root=1
    if ! have_root_access; then
      printf 'skipped %-8s %s (sudo unavailable)\n' apt-cache "$APT_CACHE_DIR"
      return 0
    fi
  fi

  before="$(path_size_bytes "$APT_CACHE_DIR" "$use_root")"
  [ "$before" -gt 0 ] || return 0

  if [ "$DRY" -eq 1 ]; then
    printf 'would clean %-8s %s\n' apt-cache "$APT_CACHE_DIR"
    add_recovered_bytes "$before"
    bump APT_CACHE_CLEANED
    return 0
  fi

  if [ "$use_root" -eq 1 ]; then
    run_root find "$APT_CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name lock -exec rm -rf -- {} + 2>/dev/null || return 0
  else
    find "$APT_CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name lock -exec rm -rf -- {} + 2>/dev/null || return 0
  fi

  after="$(path_size_bytes "$APT_CACHE_DIR" "$use_root")"
  delta=$((before - after))
  add_recovered_bytes "$delta"

  printf 'cleaned %-8s %s\n' apt-cache "$APT_CACHE_DIR"
  bump APT_CACHE_CLEANED
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repo-root) shift; REPO_ROOT="${1:-}" ;;
    --projects-root) shift; PROJECTS_ROOT="${1:-}" ;;
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
prune_project_worktrees
cleanup_sessions
cleanup_logs
cleanup_temp_files
cleanup_pip_cache
cleanup_apt_cache
write_success_stamp

printf '\nSummary (%s)\n' "$([ "$DRY" -eq 1 ] && echo dry-run || echo apply)"
printf '  stale worktrees: %d\n' "$WORKTREE_REMOVED"
printf '  pruned worktrees: %d\n' "$WORKTREE_PRUNED"
printf '  tmux sessions:   %d\n' "$TMUX_REMOVED"
printf '  logs compressed: %d\n' "$LOG_COMPRESSED"
printf '  stale logs:      %d\n' "$LOG_REMOVED"
printf '  temp files:      %d\n' "$TEMP_REMOVED"
printf '  pip caches:      %d\n' "$PIP_CACHE_CLEANED"
printf '  apt caches:      %d\n' "$APT_CACHE_CLEANED"
printf '  disk %s: %s\n' "$([ "$DRY" -eq 1 ] && echo reclaimable || echo recovered)" "$(format_bytes "$BYTES_RECOVERED")"
