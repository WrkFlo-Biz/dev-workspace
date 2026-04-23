#!/usr/bin/env bash
# apply-codex-profiles.sh — merge the Foundry profiles into ~/.codex/config.toml.
# Idempotent: only appends blocks that aren't already present.
# Works on Mac and VM.

set -euo pipefail
log() { printf '\033[1;34m[codex-profiles]\033[0m %s\n' "$*"; }

SRC="$(cd "$(dirname "$0")/.." && pwd)/codex-profiles/foundry-profiles.toml"
DEST="$HOME/.codex/config.toml"

if [ ! -f "$SRC" ]; then
  echo "missing $SRC" >&2; exit 1
fi

mkdir -p "$HOME/.codex"
touch "$DEST"

# Back up before mutating
cp "$DEST" "$DEST.bak.$(date -u +%Y%m%dT%H%M%SZ)"

# Append only the profile blocks that are not already defined.
# Simple heuristic: match the `[profiles.<name>]` header line.
while IFS= read -r line; do
  case "$line" in
    \[profiles.*\]|\[model_providers.azure-foundry\])
      header="$line"
      ;;
  esac
done <"$SRC"

# Easier path: append whole file then dedupe by hand if the user re-runs.
# We use `awk` to skip any section whose header already exists in DEST.
awk -v dest="$DEST" '
  BEGIN {
    while ((getline ln < dest) > 0) {
      if (match(ln, /^\[[^]]+\]/)) existing[substr(ln, RSTART, RLENGTH)] = 1
    }
    close(dest)
    skip = 0
  }
  /^\[[^]]+\]/ {
    hdr = substr($0, 1, RLENGTH)
    skip = (hdr in existing) ? 1 : 0
  }
  skip == 0 { print }
' "$SRC" >>"$DEST"

log "merged codex profiles into $DEST"
log "verify: codex profiles"
