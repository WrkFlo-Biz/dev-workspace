#!/usr/bin/env bash
set -euo pipefail

# Wrapper — canonical source is scripts/dws-sessions.sh
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "${SCRIPT_DIR}/../scripts/dws-sessions.sh" "$@"
