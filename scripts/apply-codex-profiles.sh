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

# Append only the sections whose header isn't already defined in DEST.
# IMPORTANT: mawk (Ubuntu default) does NOT set RSTART/RLENGTH from implicit
# /regex/ pattern matches — only match() does. Earlier version used RLENGTH
# from the pattern match and silently appended duplicates. Use match() here.
awk -v dest="$DEST" '
  BEGIN {
    while ((getline ln < dest) > 0) {
      if (match(ln, /^\[[^]]+\]/)) existing[substr(ln, RSTART, RLENGTH)] = 1
    }
    close(dest)
    skip = 0
  }
  {
    if (match($0, /^\[[^]]+\]/)) {
      hdr = substr($0, RSTART, RLENGTH)
      skip = (hdr in existing) ? 1 : 0
    }
    if (!skip) print
  }
' "$SRC" >>"$DEST"

log "merged codex profiles into $DEST"
log "verify: codex --help"
