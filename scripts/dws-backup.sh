#!/usr/bin/env bash
set -euo pipefail

MANIFEST=/tmp/dws-backup-manifest.txt
BACKUP_DIR="$HOME/backups/$(date +%F)"

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
  local count=0 repo branch sha
  mkdir -p "$BACKUP_DIR" "$(dirname "$MANIFEST")"
  : > "$MANIFEST"
  for repo in "$HOME"/projects/*; do
    [ -e "$repo" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$repo" rev-parse --short HEAD)
    sha=$(git -C "$repo" rev-parse HEAD)
    printf '%s\t%s\t%s\n' "$repo" "$branch" "$sha" >> "$MANIFEST"
    count=$((count + 1))
  done
  if [ -f "$HOME/.tmux.conf" ]; then cp -a "$HOME/.tmux.conf" "$BACKUP_DIR/.tmux.conf"; fi
  if [ -f "$HOME/.config/wrkflo/foundry.env" ]; then cp -a "$HOME/.config/wrkflo/foundry.env" "$BACKUP_DIR/foundry.env"; fi
  if [ -d "$HOME/.config/codex/profiles" ]; then cp -a "$HOME/.config/codex/profiles" "$BACKUP_DIR/profiles"; fi
  printf 'Backed up %d repos\n' "$count"
  printf 'Manifest: %s\nBackup dir: %s\n' "$MANIFEST" "$BACKUP_DIR"
  if [ -f "$BACKUP_DIR/.tmux.conf" ]; then printf '  - %s\n' "$BACKUP_DIR/.tmux.conf"; fi
  if [ -f "$BACKUP_DIR/foundry.env" ]; then printf '  - %s\n' "$BACKUP_DIR/foundry.env"; fi
  if [ -d "$BACKUP_DIR/profiles" ]; then printf '  - %s\n' "$BACKUP_DIR/profiles"; fi
}

case "${1:-}" in
  --restore) restore ;;
  "" ) backup ;;
  *) echo "usage: dws-backup.sh [--restore]" >&2; exit 1 ;;
esac
