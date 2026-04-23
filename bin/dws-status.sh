#!/usr/bin/env bash
# Wrapper — canonical source is scripts/dws-status.sh
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "${BASE_DIR}/../scripts/dws-status.sh" "$@"
