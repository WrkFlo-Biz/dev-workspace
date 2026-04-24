#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  printf 'error: %s must be sourced from a shell startup file\n' "$(basename "$0")" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/dws-env.sh"

case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) PATH="$HOME/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$SCRIPT_DIR:"*) ;;
  *) PATH="$SCRIPT_DIR:$PATH" ;;
esac
export PATH

dws() { "$SCRIPT_DIR/dws-launcher.sh" "$@"; }
dwsh() { "$SCRIPT_DIR/dws-health.sh" "$@"; }
dwss() { "$SCRIPT_DIR/dws-sessions.sh" list "$@"; }
dwsq() { "$SCRIPT_DIR/dws-quick.sh" "$@"; }

if [ -n "${PS1:-}" ] && [ -z "${DWS_MOTD_SHOWN:-}" ]; then
  export DWS_MOTD_SHOWN=1
  "$SCRIPT_DIR/dws-motd.sh"
fi
