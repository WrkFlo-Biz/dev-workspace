#!/usr/bin/env bash
set -euo pipefail

SSHD_CONFIG="${DWS_TERMIUS_MAC_FIX_SSHD_CONFIG:-/etc/ssh/sshd_config}"
HOME_DIR="${DWS_TERMIUS_MAC_FIX_HOME_DIR:-$HOME}"
SSH_DIR="${DWS_TERMIUS_MAC_FIX_SSH_DIR:-${HOME_DIR}/.ssh}"
AUTHORIZED_KEYS="${DWS_TERMIUS_MAC_FIX_AUTHORIZED_KEYS:-${SSH_DIR}/authorized_keys}"
SSHD_BIN="${DWS_TERMIUS_MAC_FIX_SSHD_BIN:-/usr/sbin/sshd}"
MANAGED_HEADER="# Managed by dev-workspace/scripts/dws-termius-mac-fix.sh"

usage() {
  cat <<'EOF'
usage: dws-termius-mac-fix.sh

Repair the common macOS SSH settings that break Termius public-key auth:
  - ensure PubkeyAuthentication yes is the first global sshd_config setting
  - ensure ~/.ssh is 700
  - ensure ~/.ssh/authorized_keys is 600
  - ensure $HOME is not group/world writable
  - verify the resulting sshd config with sshd -t -f

Environment overrides:
  DWS_TERMIUS_MAC_FIX_SSHD_CONFIG
  DWS_TERMIUS_MAC_FIX_HOME_DIR
  DWS_TERMIUS_MAC_FIX_SSH_DIR
  DWS_TERMIUS_MAC_FIX_AUTHORIZED_KEYS
  DWS_TERMIUS_MAC_FIX_SSHD_BIN
EOF
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_root_for_path() {
  local path="${1:-}" parent

  if [ "$(id -u)" -eq 0 ]; then
    return 1
  fi

  if [ -e "$path" ]; then
    [ -w "$path" ] && return 1
    return 0
  fi

  parent=$(dirname "$path")
  [ -w "$parent" ] && return 1
  return 0
}

run_for_path() {
  local path="${1:-}"
  shift

  if need_root_for_path "$path"; then
    sudo "$@"
  else
    "$@"
  fi
}

install_file() {
  local src="${1:-}" dest="${2:-}" mode="${3:-0644}"

  run_for_path "$dest" install -m "$mode" "$src" "$dest"
}

rewrite_sshd_config() {
  local tmp

  [ -f "$SSHD_CONFIG" ] || die "missing sshd_config: $SSHD_CONFIG"

  tmp=$(mktemp "${TMPDIR:-/tmp}/dws-termius-mac-fix.XXXXXX")
  awk -v header="$MANAGED_HEADER" '
    BEGIN {
      print header
      print "PubkeyAuthentication yes"
      print ""
      skip_managed = 0
    }
    {
      if ($0 == header) {
        skip_managed = 1
        next
      }
      if (skip_managed == 1) {
        if (tolower($0) ~ /^[[:space:]]*pubkeyauthentication[[:space:]]+yes[[:space:]]*$/) {
          skip_managed = 2
          next
        }
        skip_managed = 0
      }
      if (skip_managed == 2) {
        skip_managed = 0
        if ($0 ~ /^[[:space:]]*$/) {
          next
        }
      }
      print
    }
  ' "$SSHD_CONFIG" >"$tmp"

  if cmp -s "$tmp" "$SSHD_CONFIG"; then
    say "sshd_config already ensures PubkeyAuthentication yes: $SSHD_CONFIG"
    rm -f "$tmp"
    return 0
  fi

  install_file "$tmp" "$SSHD_CONFIG" 0644
  rm -f "$tmp"
  say "updated sshd_config: $SSHD_CONFIG"
}

fix_permissions() {
  mkdir -p "$SSH_DIR"
  touch "$AUTHORIZED_KEYS"

  chmod 700 "$SSH_DIR"
  chmod 600 "$AUTHORIZED_KEYS"
  chmod go-w "$HOME_DIR"

  say "set permissions: $SSH_DIR -> 700"
  say "set permissions: $AUTHORIZED_KEYS -> 600"
  say "removed group/world write from: $HOME_DIR"
}

verify_sshd_config() {
  [ -x "$SSHD_BIN" ] || die "sshd binary not executable: $SSHD_BIN"

  run_for_path "$SSHD_CONFIG" "$SSHD_BIN" -t -f "$SSHD_CONFIG"
  say "verified sshd config: $SSHD_BIN -t -f $SSHD_CONFIG"
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    '')
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac

  [ -d "$HOME_DIR" ] || die "home directory not found: $HOME_DIR"

  say "Termius macOS SSH pubkey repair"
  say "  sshd_config: $SSHD_CONFIG"
  say "  home:        $HOME_DIR"
  say "  ssh dir:     $SSH_DIR"
  say "  auth keys:   $AUTHORIZED_KEYS"
  say ""

  rewrite_sshd_config
  fix_permissions
  verify_sshd_config

  say ""
  say "If sshd is already running, reload it on macOS with:"
  say "  sudo launchctl kickstart -k system/com.openssh.sshd"
}

main "$@"
