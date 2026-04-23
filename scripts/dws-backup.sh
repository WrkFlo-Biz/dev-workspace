#!/usr/bin/env bash
set -euo pipefail

MANIFEST=/tmp/dws-backup-manifest.txt
BACKUP_DIR="$HOME/backups/$(date +%F)"
DRY_RUN=0

usage() {
  echo "usage: dws-backup.sh [--dry-run|--restore]" >&2
}

restore() {
  [ -f "$MANIFEST" ] || { echo "missing $MANIFEST" >&2; exit 1; }
  local n=0 repo branch sha
  while IFS=$'\t' read -r repo branch sha; do
    [ -n "${repo:-}" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$repo" checkout "$branch" >/dev/null
    printf 'restored %-30s %s @ %s\n' "$(basename "$repo")" "$branch" "$sha"
    n=$((n + 1))
  done < "$MANIFEST"
  printf '\nRestored %d repos from %s\n' "$n" "$MANIFEST"
}

backup() {
  local count=0 repo branch sha profiles_dir
  profiles_dir="${CODEX_PROFILES_DIR:-$HOME/.config/codex/profiles}"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$BACKUP_DIR" "$(dirname "$MANIFEST")"
    : > "$MANIFEST"
  fi
  for repo in "$HOME"/projects/*; do
    [ -e "$repo" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$repo" rev-parse --short HEAD)
    sha=$(git -C "$repo" rev-parse HEAD)
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would back up %-30s %s @ %s\n' "$(basename "$repo")" "$branch" "$sha"
    else
      printf '%s\t%s\t%s\n' "$repo" "$branch" "$sha" >> "$MANIFEST"
    fi
    count=$((count + 1))
  done
  if [ -f "$HOME/.tmux.conf" ]; then
    [ "$DRY_RUN" -eq 1 ] && printf 'would copy %s\n' "$HOME/.tmux.conf" || cp -a "$HOME/.tmux.conf" "$BACKUP_DIR/.tmux.conf"
  fi
  if [ -f "$HOME/.config/wrkflo/foundry.env" ]; then
    [ "$DRY_RUN" -eq 1 ] && printf 'would copy %s\n' "$HOME/.config/wrkflo/foundry.env" || cp -a "$HOME/.config/wrkflo/foundry.env" "$BACKUP_DIR/foundry.env"
  fi
  if [ -d "$profiles_dir" ]; then
    [ "$DRY_RUN" -eq 1 ] && printf 'would copy %s\n' "$profiles_dir" || cp -a "$profiles_dir" "$BACKUP_DIR/profiles"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\nDry run only. Would back up %d repos\n' "$count"
    printf 'Manifest: %s\nBackup dir: %s\n' "$MANIFEST" "$BACKUP_DIR"
  else
    printf 'Backed up %d repos\n' "$count"
    printf 'Manifest: %s\nBackup dir: %s\n' "$MANIFEST" "$BACKUP_DIR"
    if [ -f "$BACKUP_DIR/.tmux.conf" ]; then printf '  - %s\n' "$BACKUP_DIR/.tmux.conf"; fi
    if [ -f "$BACKUP_DIR/foundry.env" ]; then printf '  - %s\n' "$BACKUP_DIR/foundry.env"; fi
    if [ -d "$BACKUP_DIR/profiles" ]; then printf '  - %s\n' "$BACKUP_DIR/profiles"; fi
  fi
}

case "${1:-}" in
  --restore) restore ;;
  --dry-run) DRY_RUN=1; backup ;;
  "" ) backup ;;
  *) usage; exit 1 ;;
esac
