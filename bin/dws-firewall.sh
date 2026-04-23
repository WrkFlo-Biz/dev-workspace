#!/usr/bin/env bash
set -euo pipefail

TAILSCALE_SUBNET="${DWS_TAILSCALE_SUBNET:-100.64.0.0/10}"
SSH_PORT="${DWS_SSH_PORT:-22}"
TAILSCALE_PORT="${DWS_TAILSCALE_PORT:-41641}"
DEV_PORTS=(8080 9222 3000)
BACKEND="${DWS_FIREWALL_BACKEND:-}"
LOG_TAG="${DWS_FIREWALL_LOG_TAG:-dws-firewall}"
DRY=0
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'EOF'
usage: dws-firewall.sh [--dry-run] [--backend ufw|iptables] [--help]

Configures a minimal inbound firewall profile for dev-workspace:
- allow udp/41641 from anywhere for Tailscale peer traffic
- allow tcp/22 from 100.64.0.0/10
- allow tcp/8080, tcp/9222, and tcp/3000 from 100.64.0.0/10
- deny all other inbound traffic

Prefers UFW when available, otherwise falls back to iptables.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

log_msg() {
  local message="$1"

  printf '%s\n' "$message"
  if have logger; then
    logger -t "$LOG_TAG" -- "$message" >/dev/null 2>&1 || true
  fi
}

run() {
  if [ "$DRY" -eq 1 ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY=1
        ;;
      --backend)
        [ "$#" -ge 2 ] || die 'missing value for --backend'
        BACKEND="$2"
        shift
        ;;
      --backend=*)
        BACKEND="${1#*=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

ensure_root() {
  [ "$DRY" -eq 1 ] && return 0

  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi

  if have sudo; then
    exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
  fi

  die 'root privileges are required to configure the firewall'
}

detect_backend() {
  if [ -n "$BACKEND" ]; then
    case "$BACKEND" in
      ufw|iptables) ;;
      *) die "unsupported firewall backend: $BACKEND" ;;
    esac

    have "$BACKEND" || die "requested firewall backend is not installed: $BACKEND"
    return 0
  fi

  if have ufw; then
    BACKEND=ufw
  elif have iptables; then
    BACKEND=iptables
  else
    die 'neither ufw nor iptables is installed'
  fi
}

log_common_notes() {
  log_msg "using firewall backend: $BACKEND"
  log_msg "tailscale note: udp/${TAILSCALE_PORT} stays open globally so direct peers can reach this host"
}

apply_ufw() {
  local port

  log_common_notes

  run ufw --force reset
  run ufw default deny incoming
  log_msg 'default incoming policy: deny'
  run ufw default allow outgoing
  log_msg 'default outgoing policy: allow'

  run ufw allow "${TAILSCALE_PORT}/udp"
  log_msg "allow udp/${TAILSCALE_PORT} from anywhere (Tailscale peer traffic)"

  run ufw allow from "$TAILSCALE_SUBNET" to any port "$SSH_PORT" proto tcp
  log_msg "allow tcp/${SSH_PORT} from ${TAILSCALE_SUBNET} (SSH over Tailscale)"

  for port in "${DEV_PORTS[@]}"; do
    run ufw allow from "$TAILSCALE_SUBNET" to any port "$port" proto tcp
    log_msg "allow tcp/${port} from ${TAILSCALE_SUBNET} (dev port over Tailscale)"
  done

  run ufw --force enable

  if [ "$DRY" -eq 0 ]; then
    while IFS= read -r line; do
      log_msg "ufw status: $line"
    done < <(ufw status verbose)
  fi
}

apply_iptables() {
  local chain='DWS_FIREWALL_INPUT'
  local port

  log_common_notes

  if [ "$DRY" -eq 1 ]; then
    run iptables -w -N "$chain"
  else
    iptables -w -nL "$chain" >/dev/null 2>&1 || run iptables -w -N "$chain"
    while iptables -w -C INPUT -j "$chain" >/dev/null 2>&1; do
      run iptables -w -D INPUT -j "$chain"
    done
  fi

  run iptables -w -F "$chain"
  run iptables -w -I INPUT 1 -j "$chain"

  run iptables -w -A "$chain" -i lo -j ACCEPT
  log_msg 'allow loopback traffic'

  run iptables -w -A "$chain" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log_msg 'allow established and related inbound traffic'

  run iptables -w -A "$chain" -p udp --dport "$TAILSCALE_PORT" -j ACCEPT
  log_msg "allow udp/${TAILSCALE_PORT} from anywhere (Tailscale peer traffic)"

  run iptables -w -A "$chain" -p tcp -s "$TAILSCALE_SUBNET" --dport "$SSH_PORT" -j ACCEPT
  log_msg "allow tcp/${SSH_PORT} from ${TAILSCALE_SUBNET} (SSH over Tailscale)"

  for port in "${DEV_PORTS[@]}"; do
    run iptables -w -A "$chain" -p tcp -s "$TAILSCALE_SUBNET" --dport "$port" -j ACCEPT
    log_msg "allow tcp/${port} from ${TAILSCALE_SUBNET} (dev port over Tailscale)"
  done

  run iptables -w -A "$chain" -j DROP
  log_msg 'drop all other inbound IPv4 traffic'

  if [ "$DRY" -eq 0 ]; then
    while IFS= read -r line; do
      log_msg "iptables status: $line"
    done < <(iptables -w -S "$chain")

    if have netfilter-persistent; then
      run netfilter-persistent save
      log_msg 'persisted iptables rules with netfilter-persistent save'
    elif [ -d /etc/iptables ] && have iptables-save; then
      run /bin/sh -c 'iptables-save > /etc/iptables/rules.v4'
      log_msg 'saved iptables rules to /etc/iptables/rules.v4'
    else
      log_msg 'iptables rules are live only; install netfilter-persistent to persist them across reboot'
    fi
  fi
}

main() {
  parse_args "$@"
  detect_backend
  ensure_root

  case "$BACKEND" in
    ufw) apply_ufw ;;
    iptables) apply_iptables ;;
  esac

  log_msg 'firewall configuration complete'
}

main "$@"
