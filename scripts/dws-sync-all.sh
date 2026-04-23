#!/usr/bin/env bash
set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$BASE_DIR/dws-env.sh"

ROOT="${DWS_PROJECTS_DIR:-$HOME/projects}"
rows=()

for repo in "${PROJECTS[@]}"; do
  path="$ROOT/$repo"
  branch="-"; status="failed"
  if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    red "missing repo: $repo"; echo
    rows+=("$(printf '%-28s | %-12s | %s' "$repo" "$branch" "$status")")
    continue
  fi
  branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$path" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    yellow "skipping dirty repo: $repo"; echo
    status="skipped"
  elif git -C "$path" fetch --quiet && git -C "$path" pull --rebase --quiet; then
    status="updated"
  fi
  rows+=("$(printf '%-28s | %-12s | %s' "$repo" "$branch" "$status")")
done

echo
bold "project                      | branch       | status"; echo
printf '%s\n' "${rows[@]}"
