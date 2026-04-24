#!/usr/bin/env bash
# Wrapper - canonical source is scripts/dws-queue-inspector.sh
set -euo pipefail

BASE_DIR="${BASH_SOURCE[0]%/*}"
[ "$BASE_DIR" != "${BASH_SOURCE[0]}" ] || BASE_DIR='.'
BASE_DIR=$(CDPATH='' cd -- "$BASE_DIR" && pwd)
exec "${BASE_DIR}/../scripts/dws-queue-inspector.sh" "$@"
