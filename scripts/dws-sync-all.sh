#!/usr/bin/env bash
set -euo pipefail
BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
  else
    upstream=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -z "$upstream" ]; then
      yellow "skipping repo without upstream: $repo"; echo
      status="no-upstream"
    else
      remote=${upstream%%/*}
      if ! git -C "$path" fetch --quiet --prune "$remote"; then
        red "fetch failed for repo: $repo"; echo
        status="fetch-failed"
      elif ! local_head=$(git -C "$path" rev-parse HEAD 2>/dev/null); then
        red "failed to resolve HEAD for repo: $repo"; echo
        status="head-failed"
      elif ! upstream_head=$(git -C "$path" rev-parse "$upstream" 2>/dev/null); then
        red "failed to resolve upstream for repo: $repo"; echo
        status="upstream-failed"
      elif [ "$local_head" = "$upstream_head" ]; then
        status="current"
      elif git -C "$path" merge-base --is-ancestor HEAD "$upstream"; then
        if git -C "$path" merge --ff-only --quiet "$upstream"; then
          status="updated"
        else
          red "fast-forward failed for repo: $repo"; echo
          status="merge-failed"
        fi
      else
        yellow "skipping diverged repo: $repo"; echo
        status="diverged"
      fi
    fi
  fi
  rows+=("$(printf '%-28s | %-12s | %s' "$repo" "$branch" "$status")")
done

echo
bold "project                      | branch       | status"; echo
printf '%s\n' "${rows[@]}"
