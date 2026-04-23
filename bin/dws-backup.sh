#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${DWS_BACKUP_ROOT:-$HOME/backups/dev-workspace}"
KEEP_DAYS="${DWS_BACKUP_KEEP_DAYS:-14}"
MANIFEST_LEGACY="/tmp/dws-backup-manifest.txt"
TIMESTAMP="${DWS_BACKUP_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"

MODE="backup"
DRY_RUN=0
SNAPSHOT_DIR=""

REPO_COUNT=0
SAVED_COUNT=0
SKIPPED_COUNT=0
RESTORED_COUNT=0

usage() {
  cat <<'EOF'
usage: dws-backup.sh [backup|restore|cron] [options] [snapshot]

Commands:
  backup            create a new snapshot (default)
  restore [latest]  restore the newest snapshot or the given snapshot path
  cron              create a snapshot and prune old snapshots

Options:
  --dry-run         print actions without writing files
  --root DIR        backup root directory (default: ~/backups/dev-workspace)
  --snapshot DIR    explicit snapshot dir for backup or restore
  --keep-days N     retention for cron mode (default: 14)
  --restore         compatibility alias for restore latest
  -h, --help        show this help
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

say() {
  printf '%s\n' "$*"
}

mkdir_p() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would mkdir -p $1"
  else
    mkdir -p -- "$1"
  fi
}

write_text() {
  local path="$1" content="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would write $path"
  else
    mkdir -p -- "$(dirname "$path")"
    printf '%s' "$content" >"$path"
  fi
}

copy_file() {
  local src="$1" rel="$2" label="$3" dest
  dest="${SNAPSHOT_DIR}/${rel}"
  if [ ! -f "$src" ]; then
    say "skip ${label}: ${src} missing"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would back up ${label}: ${src} -> ${dest}"
  else
    mkdir -p -- "$(dirname "$dest")"
    cp -a -- "$src" "$dest"
  fi
  SAVED_COUNT=$((SAVED_COUNT + 1))
}

copy_dir() {
  local src="$1" rel="$2" label="$3" dest
  dest="${SNAPSHOT_DIR}/${rel}"
  if [ ! -d "$src" ]; then
    say "skip ${label}: ${src} missing"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would back up ${label}: ${src} -> ${dest}"
  else
    mkdir -p -- "$(dirname "$dest")"
    cp -a -- "$src" "$dest"
  fi
  SAVED_COUNT=$((SAVED_COUNT + 1))
}

restore_file() {
  local rel="$1" dest="$2" label="$3" src
  src="${SNAPSHOT_DIR}/${rel}"
  if [ ! -f "$src" ]; then
    say "skip restore ${label}: ${src} missing"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would restore ${label}: ${src} -> ${dest}"
  else
    mkdir -p -- "$(dirname "$dest")"
    cp -a -- "$src" "$dest"
  fi
  RESTORED_COUNT=$((RESTORED_COUNT + 1))
}

restore_dir() {
  local rel="$1" dest="$2" label="$3" src
  src="${SNAPSHOT_DIR}/${rel}"
  if [ ! -d "$src" ]; then
    say "skip restore ${label}: ${src} missing"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would restore ${label}: ${src} -> ${dest}"
  else
    mkdir -p -- "$(dirname "$dest")"
    rm -rf -- "$dest"
    cp -a -- "$src" "$dest"
  fi
  RESTORED_COUNT=$((RESTORED_COUNT + 1))
}

latest_snapshot() {
  [ -d "$BACKUP_ROOT" ] || return 0
  if [ -L "${BACKUP_ROOT}/latest" ]; then
    readlink -f -- "${BACKUP_ROOT}/latest"
    return 0
  fi
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1
}

write_repo_manifest() {
  local manifest_path repo branch sha lines
  manifest_path="${SNAPSHOT_DIR}/meta/repo-manifest.tsv"
  lines=""
  REPO_COUNT=0

  for repo in "$HOME"/projects/*; do
    [ -e "$repo" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$repo" rev-parse --short HEAD)
    sha=$(git -C "$repo" rev-parse HEAD)
    lines="${lines}${repo}"$'\t'"${branch}"$'\t'"${sha}"$'\n'
    REPO_COUNT=$((REPO_COUNT + 1))
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    say "would write repo manifest: ${manifest_path}"
    say "would refresh legacy manifest: ${MANIFEST_LEGACY}"
  else
    mkdir -p -- "$(dirname "$manifest_path")" "$(dirname "$MANIFEST_LEGACY")"
    printf '%s' "$lines" >"$manifest_path"
    printf '%s' "$lines" >"$MANIFEST_LEGACY"
  fi
}

write_metadata() {
  local summary
  summary=$(
    cat <<EOF
created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
host=$(hostname -s 2>/dev/null || hostname)
backup_root=${BACKUP_ROOT}
snapshot_dir=${SNAPSHOT_DIR}
repo_count=${REPO_COUNT}
saved_items=${SAVED_COUNT}
skipped_items=${SKIPPED_COUNT}
EOF
  )
  write_text "${SNAPSHOT_DIR}/meta/summary.txt" "$summary"
}

prune_old_snapshots() {
  local path pruned
  pruned=0
  [ -d "$BACKUP_ROOT" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$path" != "$SNAPSHOT_DIR" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      say "would prune old snapshot: ${path}"
    else
      rm -rf -- "$path"
      say "pruned old snapshot: ${path}"
    fi
    pruned=$((pruned + 1))
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" | sort)
  if [ "$pruned" -eq 0 ]; then
    say "old snapshot prune: none"
  fi
}

set_latest_symlink() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would refresh latest symlink: ${BACKUP_ROOT}/latest -> ${SNAPSHOT_DIR}"
  else
    ln -sfn -- "$SNAPSHOT_DIR" "${BACKUP_ROOT}/latest"
  fi
}

backup_runtime_files() {
  copy_file "$HOME/.tmux.conf" "home/.tmux.conf" "tmux config"
  copy_file "$HOME/.config/wrkflo/foundry.env" "home/.config/wrkflo/foundry.env" "Foundry env"
  copy_dir "${CODEX_PROFILES_DIR:-$HOME/.config/codex/profiles}" "home/.config/codex/profiles" "Codex profiles"
  copy_file "$HOME/.local/state/wrkflo-orchestrator/state.db" "runtime/wrkflo-orchestrator/state.db" "orchestrator state.db"
  copy_file "/tmp/task-queue.json" "runtime/tmp/task-queue.json" "planner queue"
  copy_file "/tmp/planner-status.md" "runtime/tmp/planner-status.md" "planner status"
  copy_file "/tmp/planner-state.json" "runtime/tmp/planner-state.json" "planner state"
  copy_file "/tmp/monitor-log.txt" "runtime/logs/monitor-log.txt" "monitor log"
  copy_file "/tmp/orchestrator-monitor.log" "runtime/logs/orchestrator-monitor.log" "orchestrator monitor log"
  copy_file "/tmp/planner-log.txt" "runtime/logs/planner-log.txt" "planner log"
  copy_file "/tmp/orchestrator-status.txt" "runtime/status/orchestrator-status.txt" "planner handoff status"
}

run_backup() {
  if [ -z "$SNAPSHOT_DIR" ]; then
    SNAPSHOT_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p -- "$SNAPSHOT_DIR"
  fi

  write_repo_manifest
  backup_runtime_files
  write_metadata
  set_latest_symlink

  say
  say "Backup complete"
  say "  snapshot: ${SNAPSHOT_DIR}"
  say "  repos:    ${REPO_COUNT}"
  say "  saved:    ${SAVED_COUNT}"
  say "  skipped:  ${SKIPPED_COUNT}"
}

restore_repo_manifest() {
  local manifest_path repo branch sha
  manifest_path="${SNAPSHOT_DIR}/meta/repo-manifest.tsv"
  [ -f "$manifest_path" ] || { say "skip repo restore: ${manifest_path} missing"; return 0; }

  while IFS=$'\t' read -r repo branch sha; do
    [ -n "${repo:-}" ] || continue
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      say "skip repo restore: ${repo} missing"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      say "would restore repo $(basename "$repo"): branch=${branch} sha=${sha}"
    elif git -C "$repo" show-ref --verify --quiet "refs/heads/${branch}"; then
      if git -C "$repo" checkout "$branch" >/dev/null 2>&1; then
        say "restored repo $(basename "$repo"): branch=${branch}"
        RESTORED_COUNT=$((RESTORED_COUNT + 1))
      else
        say "skip repo restore $(basename "$repo"): could not checkout branch ${branch}"
      fi
    else
      if git -C "$repo" checkout "$sha" >/dev/null 2>&1; then
        say "restored repo $(basename "$repo"): detached ${sha}"
        RESTORED_COUNT=$((RESTORED_COUNT + 1))
      else
        say "skip repo restore $(basename "$repo"): could not checkout ${sha}"
      fi
    fi
  done <"$manifest_path"
}

run_restore() {
  if [ -z "$SNAPSHOT_DIR" ] || [ "$SNAPSHOT_DIR" = "latest" ]; then
    SNAPSHOT_DIR=$(latest_snapshot)
  fi
  [ -n "${SNAPSHOT_DIR:-}" ] || die "no backup snapshot found under ${BACKUP_ROOT}"
  [ -d "$SNAPSHOT_DIR" ] || die "snapshot not found: ${SNAPSHOT_DIR}"

  restore_repo_manifest
  restore_file "home/.tmux.conf" "$HOME/.tmux.conf" "tmux config"
  restore_file "home/.config/wrkflo/foundry.env" "$HOME/.config/wrkflo/foundry.env" "Foundry env"
  restore_dir "home/.config/codex/profiles" "${CODEX_PROFILES_DIR:-$HOME/.config/codex/profiles}" "Codex profiles"
  restore_file "runtime/wrkflo-orchestrator/state.db" "$HOME/.local/state/wrkflo-orchestrator/state.db" "orchestrator state.db"
  restore_file "runtime/tmp/task-queue.json" "/tmp/task-queue.json" "planner queue"
  restore_file "runtime/tmp/planner-status.md" "/tmp/planner-status.md" "planner status"
  restore_file "runtime/tmp/planner-state.json" "/tmp/planner-state.json" "planner state"
  restore_file "runtime/logs/monitor-log.txt" "/tmp/monitor-log.txt" "monitor log"
  restore_file "runtime/logs/orchestrator-monitor.log" "/tmp/orchestrator-monitor.log" "orchestrator monitor log"
  restore_file "runtime/logs/planner-log.txt" "/tmp/planner-log.txt" "planner log"
  restore_file "runtime/status/orchestrator-status.txt" "/tmp/orchestrator-status.txt" "planner handoff status"

  say
  say "Restore complete"
  say "  snapshot:  ${SNAPSHOT_DIR}"
  say "  restored:  ${RESTORED_COUNT}"
}

case "${1:-}" in
  backup|cron|restore)
    MODE="$1"
    shift
    ;;
  --restore)
    MODE="restore"
    shift
    ;;
  "" ) ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --root)
      shift
      BACKUP_ROOT="${1:-}"
      ;;
    --snapshot|--snapshot-dir)
      shift
      SNAPSHOT_DIR="${1:-}"
      ;;
    --keep-days)
      shift
      KEEP_DAYS="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ "$MODE" = "restore" ] && [ -z "$SNAPSHOT_DIR" ]; then
        SNAPSHOT_DIR="$1"
      else
        usage >&2
        exit 1
      fi
      ;;
  esac
  shift
done

is_int "$KEEP_DAYS" || die "--keep-days must be an integer"

case "$MODE" in
  backup)
    run_backup
    ;;
  cron)
    run_backup
    prune_old_snapshots
    ;;
  restore)
    run_restore
    ;;
esac
