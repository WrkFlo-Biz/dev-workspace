#!/usr/bin/env bash
set -euo pipefail
BASE_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$BASE_DIR/dws-env.sh"

TARGET="${DWS_TUNNEL_HOST:-moses@dev-workspace-vm}"
PRINT=0

usage() {
  printf 'usage: %s [--print] {orch|cdp|gui|all|custom <local_port> <remote_host> <remote_port>} [ssh_target]\n' "$(basename "$0")"
}

host_of() { printf '%s\n' "$1" | sed 's#^[a-z]*://##; s#[:/].*##'; }

[ $# -gt 0 ] || { usage >&2; exit 1; }
if [ "${1:-}" = "--print" ]; then PRINT=1; shift; fi
[ $# -gt 0 ] || { usage >&2; exit 1; }

cmd=(ssh -N -o ExitOnForwardFailure=yes)
case "$1" in
  orch) cmd+=(-L 8787:127.0.0.1:8787); shift ;;
  cdp) cmd+=(-L 9222:"$(host_of "$MAC_CDP_URL")":9222); shift ;;
  gui) cmd+=(-L 9223:"$(host_of "$MAC_GUI_URL")":9223); shift ;;
  all)
    cmd+=(
      -L 8787:127.0.0.1:8787
      -L 9222:"$(host_of "$MAC_CDP_URL")":9222
      -L 9223:"$(host_of "$MAC_GUI_URL")":9223
    )
    shift
    ;;
  custom)
    [ $# -ge 4 ] || { usage >&2; exit 1; }
    cmd+=(-L "$2:$3:$4")
    shift 4
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac

[ $# -le 1 ] || { usage >&2; exit 1; }
[ $# -eq 1 ] && TARGET="$1"
cmd+=("$TARGET")

if [ "$PRINT" -eq 1 ]; then
  printf '%q ' "${cmd[@]}"
  echo
else
  exec "${cmd[@]}"
fi
