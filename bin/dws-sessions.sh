#!/usr/bin/env bash
set -euo pipefail

# Wrapper — canonical source is scripts/dws-sessions.sh
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR='.'
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd)
exec "${SCRIPT_DIR}/../scripts/dws-sessions.sh" "$@"
