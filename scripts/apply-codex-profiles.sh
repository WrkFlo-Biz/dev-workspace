#!/usr/bin/env bash
# apply-codex-profiles.sh — merge Foundry profile fragments into ~/.codex/config.toml.
# Idempotent: only appends sections that aren't already present.
# Works on Mac and VM.

set -euo pipefail
log() { printf '\033[1;34m[codex-profiles]\033[0m %s\n' "$*"; }

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)/config/codex-profiles"
DEST="$HOME/.codex/config.toml"

if [ ! -d "$SRC_DIR" ]; then
  echo "missing $SRC_DIR" >&2; exit 1
fi

mkdir -p "$HOME/.codex"
touch "$DEST"

mapfile -t SOURCES < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.toml' | sort)
[ "${#SOURCES[@]}" -gt 0 ] || { echo "no profile fragments in $SRC_DIR" >&2; exit 1; }

# Back up before mutating
cp "$DEST" "$DEST.bak.$(date -u +%Y%m%dT%H%M%SZ)"

merged=0
for src in "${SOURCES[@]}"; do
  header=$(awk 'match($0, /^\[[^]]+\]$/) { print substr($0, RSTART, RLENGTH); exit }' "$src")
  [ -n "${header:-}" ] || { echo "missing TOML section header in $src" >&2; exit 1; }
  if grep -Fqx "$header" "$DEST"; then
    continue
  fi
  printf '\n' >>"$DEST"
  cat "$src" >>"$DEST"
  printf '\n' >>"$DEST"
  merged=$((merged + 1))
done

log "merged $merged profile fragments into $DEST"
log "verify: codex --help"
