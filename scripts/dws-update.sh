#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=0 DRY=0
FILES=(
  "$REPO/config/tmux.conf:$HOME/.tmux.conf:0644:~/.tmux.conf"
  "$REPO/scripts/dws-health.sh:$HOME/bin/dws-health.sh:0755:~/bin/dws-health.sh"
  "$REPO/scripts/dws-health-check.sh:$HOME/bin/dws-health-check.sh:0755:~/bin/dws-health-check.sh"
  "$REPO/scripts/dws-notify.sh:$HOME/bin/dws-notify.sh:0755:~/bin/dws-notify.sh"
)

usage() {
  cat <<'EOF'
usage: dws-update.sh [--force] [--dry-run] [--help]
  --force    skip diff confirmation, just apply
  --dry-run  show what would change without applying
  --help     show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
  shift
done

echo "Pulling latest dev-workspace changes..."
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
  echo "Skipping git pull: repo has local changes; using current checkout."
elif git -C "$REPO" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  git -C "$REPO" pull --ff-only
else
  echo "Skipping git pull: current branch has no upstream; using current checkout."
fi

changes=(); tmux_changed=0; echo
for item in "${FILES[@]}"; do
  IFS=: read -r src dest mode label <<<"$item"
  if [ ! -f "$dest" ] || ! cmp -s "$src" "$dest"; then
    changes+=("$item"); [ "$dest" = "$HOME/.tmux.conf" ] && tmux_changed=1
    printf '== %s ==\n' "$label"
    diff -u "${dest:-/dev/null}" "$src" 2>/dev/null || diff -u /dev/null "$src" || true
    echo
  fi
done

[ "${#changes[@]}" -gt 0 ] || { echo "No deployed file changes."; exit 0; }
if [ "$DRY" -eq 1 ]; then
  echo "Would update:"; for item in "${changes[@]}"; do IFS=: read -r _ _ _ label <<<"$item"; printf '  - %s\n' "$label"; done; exit 0
fi
if [ "$FORCE" -ne 1 ]; then
  read -r -p "Apply these changes? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

applied=()
for item in "${changes[@]}"; do
  IFS=: read -r src dest mode label <<<"$item"
  mkdir -p "$(dirname "$dest")"; install -m "$mode" "$src" "$dest"; applied+=("$label")
done
if [ "$tmux_changed" -eq 1 ]; then
  tmux source-file "$HOME/.tmux.conf" >/dev/null 2>&1 && applied+=("tmux reloaded") || applied+=("tmux reload skipped")
fi

echo "Changed:"; printf '  - %s\n' "${applied[@]}"
