#!/usr/bin/env bash
set -euo pipefail

# Wrapper — canonical source is scripts/dws-reboot-drill.sh
BASE_DIR="${BASH_SOURCE[0]%/*}"
[ "$BASE_DIR" != "${BASH_SOURCE[0]}" ] || BASE_DIR='.'
BASE_DIR=$(CDPATH='' cd -- "$BASE_DIR" && pwd)
exec "${BASE_DIR}/../scripts/dws-reboot-drill.sh" "$@"
