#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASH_SOURCE[0]%/*}"
[ "$BASE_DIR" != "${BASH_SOURCE[0]}" ] || BASE_DIR='.'
BASE_DIR=$(CDPATH='' cd -- "$BASE_DIR" && pwd)
exec "${BASH:-/usr/bin/bash}" "${BASE_DIR}/../scripts/dws-firewall.sh" "$@"
