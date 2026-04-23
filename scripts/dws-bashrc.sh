#!/usr/bin/env bash

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

alias dws="$SCRIPT_DIR/dws-launcher.sh"
alias dwsh="$SCRIPT_DIR/dws-health.sh"
alias dwss="$SCRIPT_DIR/dws-sessions.sh list"
alias dwsq="$SCRIPT_DIR/dws-quick.sh"

if [ -n "${PS1:-}" ] && [ -z "${DWS_MOTD_SHOWN:-}" ]; then
  export DWS_MOTD_SHOWN=1
  "$SCRIPT_DIR/dws-motd.sh"
fi
