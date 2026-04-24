#!/usr/bin/env bash
set -euo pipefail

TAILSCALE_SUBNET="${DWS_TAILSCALE_SUBNET:-100.64.0.0/10}"
SSH_PORT="${DWS_SSH_PORT:-22}"
TAILSCALE_PORT="${DWS_TAILSCALE_PORT:-41641}"
DEV_PORTS=(8080 8081 8100 9222 3000)
BACKEND="${DWS_FIREWALL_BACKEND:-}"
LOG_TAG="${DWS_FIREWALL_LOG_TAG:-dws-firewall}"
STATE_DIR="${DWS_FIREWALL_STATE_DIR:-/var/lib/dws/firewall}"
IPTABLES_CHAIN='DWS_FIREWALL_INPUT'
ACTION='apply'
DRY=0
ORIGINAL_ARGS=("$@")
SNAPSHOT_DIR=''
ROLLBACK_ON_ERROR=0

usage() {
  cat <<'EOF'
usage: dws-firewall.sh [--dry-run] [--backend ufw|iptables] [--verify] [--rollback] [--help]

Default action snapshots the current backend state, applies the repo ingress
policy, and verifies the result:
- allow udp/41641 from anywhere for Tailscale peer traffic
- allow tcp/22 from anywhere for SSH relay compatibility
- allow tcp/8080, tcp/9222, and tcp/3000 from 100.64.0.0/10
- deny all other inbound traffic

Modes:
- default: apply the policy
- --verify: read-only verification of the active repo-managed backend
- --rollback: restore the most recent saved snapshot
- --dry-run: print the apply or rollback actions without changing the host

Environment:
- DWS_FIREWALL_STATE_DIR overrides the rollback snapshot directory

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

run_input_file() {
  local input_file="$1"
  shift

  if [ "$DRY" -eq 1 ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf ' < %q\n' "$input_file"
    return 0
  fi

  "$@" <"$input_file"
}

set_action() {
  [ "$ACTION" = 'apply' ] || die 'only one of --verify or --rollback can be used'
  ACTION="$1"
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
      --verify)
        set_action 'verify'
        ;;
      --rollback)
        set_action 'rollback'
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
  if [ "$DRY" -eq 1 ] || [ "$ACTION" = 'verify' ]; then
    return 0
  fi

  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi

  if have sudo; then
    exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
  fi

  die 'root privileges are required to configure the firewall'
}

capture_cmd() {
  local output status

  if output=$("$@" 2>&1); then
    printf '%s' "$output"
    return 0
  fi
  status=$?

  if [ "$ACTION" = 'verify' ] && have sudo; then
    case "$output" in
      *"You need to be root"*|*"Permission denied"*|*"Operation not permitted"*)
        if output=$(sudo -n -- "$@" 2>&1); then
          printf '%s' "$output"
          return 0
        fi
        status=$?
        ;;
    esac
  fi

  printf '%s' "$output"
  return "$status"
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

read_snapshot_link() {
  local link_path="$1"

  [ -L "$link_path" ] || return 1
  readlink -f "$link_path"
}

latest_snapshot_path() {
  if [ -n "$BACKEND" ]; then
    read_snapshot_link "${STATE_DIR}/latest-${BACKEND}" || true
    return 0
  fi

  read_snapshot_link "${STATE_DIR}/latest" || true
}

ufw_is_active() {
  local output

  have ufw || return 1
  output=$(capture_cmd ufw status 2>/dev/null || true)
  printf '%s\n' "$output" | grep -q '^Status: active'
}

iptables_chain_exists() {
  have iptables || return 1
  capture_cmd iptables -w -S "$IPTABLES_CHAIN" >/dev/null 2>&1
}

resolve_backend_for_verify() {
  local snapshot

  if [ -n "$BACKEND" ]; then
    detect_backend
    return 0
  fi

  snapshot=$(latest_snapshot_path)
  if [ -n "$snapshot" ] && [ -f "$snapshot/backend.txt" ]; then
    BACKEND=$(head -n 1 "$snapshot/backend.txt")
    detect_backend
    return 0
  fi

  if ufw_is_active; then
    BACKEND=ufw
    return 0
  fi

  if iptables_chain_exists; then
    BACKEND=iptables
    return 0
  fi

  detect_backend
}

resolve_snapshot_for_rollback() {
  local snapshot

  snapshot=$(latest_snapshot_path)
  [ -n "$snapshot" ] || die "no rollback snapshot found under ${STATE_DIR}"
  [ -d "$snapshot" ] || die "rollback snapshot path is missing: ${snapshot}"

  if [ -z "$BACKEND" ] && [ -f "$snapshot/backend.txt" ]; then
    BACKEND=$(head -n 1 "$snapshot/backend.txt")
  fi
  [ -n "$BACKEND" ] || die "rollback snapshot ${snapshot} is missing backend metadata"

  detect_backend
  SNAPSHOT_DIR="$snapshot"
}

timestamp_compact() {
  date -u +%Y%m%dT%H%M%SZ
}

timestamp_rfc3339() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

prepare_snapshot_dir() {
  SNAPSHOT_DIR="${STATE_DIR}/snapshots/$(timestamp_compact)-${BACKEND}"
}

write_snapshot_file() {
  local rel_path="$1"
  local content="$2"

  printf '%s' "$content" >"${SNAPSHOT_DIR}/${rel_path}"
}

snapshot_file_state() {
  local source="$1"
  local target="${SNAPSHOT_DIR}/root/${source#/}"

  if [ -e "$source" ]; then
    mkdir -p -- "$(dirname "$target")"
    cp -a -- "$source" "$target"
    printf 'present\t%s\n' "$source" >>"${SNAPSHOT_DIR}/files.tsv"
  else
    printf 'missing\t%s\n' "$source" >>"${SNAPSHOT_DIR}/files.tsv"
  fi
}

snapshot_ufw_state() {
  local output active='inactive'

  output=$(ufw status 2>/dev/null || true)
  case "$output" in
    *"Status: active"*) active='active' ;;
  esac

  write_snapshot_file 'ufw-state.txt' "${active}"$'\n'
  snapshot_file_state '/etc/default/ufw'
  snapshot_file_state '/etc/ufw/ufw.conf'
  snapshot_file_state '/etc/ufw/user.rules'
  snapshot_file_state '/etc/ufw/user6.rules'

  ufw status verbose >"${SNAPSHOT_DIR}/ufw-status-verbose.txt" 2>&1 || true
  ufw status numbered >"${SNAPSHOT_DIR}/ufw-status-numbered.txt" 2>&1 || true
}

snapshot_iptables_state() {
  have iptables-save || die 'iptables backend requires iptables-save to create rollback snapshots'
  have iptables-restore || die 'iptables backend requires iptables-restore to restore rollback snapshots'

  iptables-save >"${SNAPSHOT_DIR}/iptables.save"
}

update_latest_snapshot_links() {
  ln -sfn -- "$SNAPSHOT_DIR" "${STATE_DIR}/latest"
  ln -sfn -- "$SNAPSHOT_DIR" "${STATE_DIR}/latest-${BACKEND}"
}

save_rollback_snapshot() {
  prepare_snapshot_dir

  if [ "$DRY" -eq 1 ]; then
    log_msg "dry-run: would snapshot current ${BACKEND} state under ${SNAPSHOT_DIR}"
    return 0
  fi

  mkdir -p -- "${STATE_DIR}/snapshots" "${SNAPSHOT_DIR}/root"
  : >"${SNAPSHOT_DIR}/files.tsv"
  write_snapshot_file 'backend.txt' "${BACKEND}"$'\n'
  write_snapshot_file 'created-at.txt' "$(timestamp_rfc3339)"$'\n'
  write_snapshot_file 'tailscale-subnet.txt' "${TAILSCALE_SUBNET}"$'\n'

  case "$BACKEND" in
    ufw) snapshot_ufw_state ;;
    iptables) snapshot_iptables_state ;;
  esac

  update_latest_snapshot_links
  log_msg "saved rollback snapshot: ${SNAPSHOT_DIR}"
}

restore_snapshot_files() {
  local snapshot="$1"
  local state path source

  [ -f "${snapshot}/files.tsv" ] || return 0

  while IFS=$'\t' read -r state path; do
    [ -n "$path" ] || continue
    case "$state" in
      present)
        source="${snapshot}/root/${path#/}"
        [ -e "$source" ] || die "rollback snapshot is missing expected file: ${source}"
        if [ "$DRY" -eq 1 ]; then
          run mkdir -p -- "$(dirname "$path")"
          run cp -a -- "$source" "$path"
        else
          mkdir -p -- "$(dirname "$path")"
          cp -a -- "$source" "$path"
        fi
        ;;
      missing)
        if [ "$DRY" -eq 1 ]; then
          run rm -f -- "$path"
        else
          rm -f -- "$path"
        fi
        ;;
      *)
        die "unknown rollback manifest entry: ${state}"
        ;;
    esac
  done <"${snapshot}/files.tsv"
}

log_common_notes() {
  log_msg "using firewall backend: $BACKEND"
  log_msg "tailscale note: udp/${TAILSCALE_PORT} stays open globally so direct peers can reach this host"
  log_msg "ssh note: tcp/${SSH_PORT} restricted to ${TAILSCALE_SUBNET} (Tailscale only)"
  log_msg "tailscale subnet allowlist: dev ports stay restricted to ${TAILSCALE_SUBNET}"
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
  log_msg "allow tcp/${SSH_PORT} from ${TAILSCALE_SUBNET} (SSH over Tailscale only)"

  for port in "${DEV_PORTS[@]}"; do
    run ufw allow from "$TAILSCALE_SUBNET" to any port "$port" proto tcp
    log_msg "allow tcp/${port} from ${TAILSCALE_SUBNET} (dev port over Tailscale)"
  done

  run ufw --force enable
}

persist_iptables_rules() {
  if have netfilter-persistent; then
    run netfilter-persistent save
    if [ "$DRY" -eq 1 ]; then
      log_msg 'dry-run: would persist iptables rules with netfilter-persistent save'
    else
      log_msg 'persisted iptables rules with netfilter-persistent save'
    fi
  elif [ -d /etc/iptables ] && have iptables-save; then
    if [ "$DRY" -eq 1 ]; then
      printf 'DRY-RUN: /bin/sh -c %q\n' 'iptables-save > /etc/iptables/rules.v4'
      log_msg 'dry-run: would save iptables rules to /etc/iptables/rules.v4'
    else
      /bin/sh -c 'iptables-save > /etc/iptables/rules.v4'
      log_msg 'saved iptables rules to /etc/iptables/rules.v4'
    fi
  else
    log_msg 'iptables rules are live only; install netfilter-persistent to persist them across reboot'
  fi
}

apply_iptables() {
  local port

  log_common_notes

  if [ "$DRY" -eq 1 ]; then
    run iptables -w -N "$IPTABLES_CHAIN"
  else
    iptables -w -nL "$IPTABLES_CHAIN" >/dev/null 2>&1 || run iptables -w -N "$IPTABLES_CHAIN"
    while iptables -w -C INPUT -j "$IPTABLES_CHAIN" >/dev/null 2>&1; do
      run iptables -w -D INPUT -j "$IPTABLES_CHAIN"
    done
  fi

  run iptables -w -F "$IPTABLES_CHAIN"
  run iptables -w -I INPUT 1 -j "$IPTABLES_CHAIN"

  run iptables -w -A "$IPTABLES_CHAIN" -i lo -j ACCEPT
  log_msg 'allow loopback traffic'

  run iptables -w -A "$IPTABLES_CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log_msg 'allow established and related inbound traffic'

  run iptables -w -A "$IPTABLES_CHAIN" -p udp --dport "$TAILSCALE_PORT" -j ACCEPT
  log_msg "allow udp/${TAILSCALE_PORT} from anywhere (Tailscale peer traffic)"

  run iptables -w -A "$IPTABLES_CHAIN" -p tcp -s "$TAILSCALE_SUBNET" --dport "$SSH_PORT" -j ACCEPT
  log_msg "allow tcp/${SSH_PORT} from ${TAILSCALE_SUBNET} (SSH over Tailscale only)"

  for port in "${DEV_PORTS[@]}"; do
    run iptables -w -A "$IPTABLES_CHAIN" -p tcp -s "$TAILSCALE_SUBNET" --dport "$port" -j ACCEPT
    log_msg "allow tcp/${port} from ${TAILSCALE_SUBNET} (dev port over Tailscale)"
  done

  run iptables -w -A "$IPTABLES_CHAIN" -j DROP
  log_msg 'drop all other inbound IPv4 traffic'

  persist_iptables_rules
}

verify_pass() {
  log_msg "verification passed: $1"
}

verify_fail() {
  log_msg "verification failed: $1"
}

ufw_has_rule() {
  local lines="$1"
  local target="$2"
  local source="$3"
  local line

  while IFS= read -r line; do
    case "$line" in
      *"$target"*'ALLOW IN'*"$source"*) return 0 ;;
    esac
  done <<<"$lines"

  return 1
}

ufw_has_public_tcp_rule() {
  local lines="$1"
  local target="$2"
  local line

  while IFS= read -r line; do
    case "$line" in
      *"$target"*'ALLOW IN'*'Anywhere'*) return 0 ;;
    esac
  done <<<"$lines"

  return 1
}

verify_ufw() {
  local verbose numbered port

  verbose=$(capture_cmd ufw status verbose) || die "unable to read ufw status: ${verbose:-unknown error}"
  numbered=$(capture_cmd ufw status numbered) || die "unable to read ufw numbered status: ${numbered:-unknown error}"

  if printf '%s\n' "$verbose" | grep -q '^Status: active'; then
    verify_pass 'ufw is active'
  else
    verify_fail 'ufw is not active'
    return 1
  fi

  if printf '%s\n' "$verbose" | grep -Eq '^Default: deny \(incoming\), allow \(outgoing\)'; then
    verify_pass 'ufw defaults deny incoming and allow outgoing'
  else
    verify_fail 'ufw defaults are not deny incoming / allow outgoing'
    return 1
  fi

  if ufw_has_rule "$numbered" "${TAILSCALE_PORT}/udp" 'Anywhere'; then
    verify_pass "udp/${TAILSCALE_PORT} stays open globally for Tailscale peer traffic"
  else
    verify_fail "missing public udp/${TAILSCALE_PORT} rule for Tailscale peer traffic"
    return 1
  fi

  if ! ufw_has_rule "$numbered" "${SSH_PORT}/tcp" "$TAILSCALE_SUBNET"; then
    verify_fail "missing tcp/${SSH_PORT} allow rule for ${TAILSCALE_SUBNET}"
    return 1
  fi
  if ufw_has_public_tcp_rule "$numbered" "${SSH_PORT}/tcp"; then
    verify_fail "unexpected public tcp/${SSH_PORT} rule — SSH should be Tailscale-only"
    return 1
  fi
  verify_pass "tcp/${SSH_PORT} is restricted to ${TAILSCALE_SUBNET}"

  for port in "${DEV_PORTS[@]}"; do
    if ! ufw_has_rule "$numbered" "${port}/tcp" "$TAILSCALE_SUBNET"; then
      verify_fail "missing tcp/${port} allow rule for ${TAILSCALE_SUBNET}"
      return 1
    fi
    if ufw_has_public_tcp_rule "$numbered" "${port}/tcp"; then
      verify_fail "unexpected public tcp/${port} rule detected"
      return 1
    fi
    verify_pass "tcp/${port} is restricted to ${TAILSCALE_SUBNET}"
  done
}

iptables_line_matches() {
  local line="$1"
  shift
  local fragment

  for fragment in "$@"; do
    case "$line" in
      *"$fragment"*) ;;
      *)
        return 1
        ;;
    esac
  done

  return 0
}

iptables_line_has_source_selector() {
  case "$1" in
    *' -s '*|*' --source '*) return 0 ;;
    *) return 1 ;;
  esac
}

iptables_line_has_destination_selector() {
  case "$1" in
    *' -d '*|*' --destination '*) return 0 ;;
    *) return 1 ;;
  esac
}

iptables_line_has_interface_selector() {
  case "$1" in
    *' -i '*|*' --in-interface '*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_iptables_chain_rules() {
  local chain_rules="$1"
  local definition_count expected_rule_count index port rule_line
  local -a chain_rule_lines=()

  definition_count=$(printf '%s\n' "$chain_rules" | grep -Fxc -- "-N ${IPTABLES_CHAIN}" || true)
  if [ "$definition_count" -ne 1 ]; then
    verify_fail "${IPTABLES_CHAIN} definition is missing or duplicated"
    return 1
  fi

  while IFS= read -r rule_line; do
    case "$rule_line" in
      "-A ${IPTABLES_CHAIN}"*) chain_rule_lines+=("$rule_line") ;;
    esac
  done <<<"$chain_rules"

  expected_rule_count=$(( ${#DEV_PORTS[@]} + 5 ))
  if [ "${#chain_rule_lines[@]}" -ne "$expected_rule_count" ]; then
    verify_fail "${IPTABLES_CHAIN} rule count does not match the repo policy"
    return 1
  fi

  if iptables_line_matches "${chain_rule_lines[0]}" "-A ${IPTABLES_CHAIN}" "-i lo" "-j ACCEPT"; then
    verify_pass 'loopback traffic is allowed'
  else
    verify_fail 'missing loopback allow rule'
    return 1
  fi

  if iptables_line_matches "${chain_rule_lines[1]}" "-A ${IPTABLES_CHAIN}" "--ctstate RELATED,ESTABLISHED" "-j ACCEPT"; then
    verify_pass 'related and established traffic is allowed'
  else
    verify_fail 'missing related/established allow rule'
    return 1
  fi

  if ! iptables_line_matches "${chain_rule_lines[2]}" "-A ${IPTABLES_CHAIN}" "-p udp" "--dport ${TAILSCALE_PORT}" "-j ACCEPT"; then
    verify_fail "missing public udp/${TAILSCALE_PORT} allow rule"
    return 1
  fi
  if iptables_line_has_source_selector "${chain_rule_lines[2]}" ||
     iptables_line_has_destination_selector "${chain_rule_lines[2]}" ||
     iptables_line_has_interface_selector "${chain_rule_lines[2]}"; then
    verify_fail "udp/${TAILSCALE_PORT} rule does not match the expected public ingress policy"
    return 1
  fi
  verify_pass "udp/${TAILSCALE_PORT} stays open globally for Tailscale peer traffic"

  if ! iptables_line_matches "${chain_rule_lines[3]}" "-A ${IPTABLES_CHAIN}" "-p tcp" "-s ${TAILSCALE_SUBNET}" "--dport ${SSH_PORT}" "-j ACCEPT"; then
    verify_fail "tcp/${SSH_PORT} rule does not match the expected ${TAILSCALE_SUBNET} restriction"
    return 1
  fi
  verify_pass "tcp/${SSH_PORT} is restricted to ${TAILSCALE_SUBNET}"

  index=4
  for port in "${DEV_PORTS[@]}"; do
    rule_line="${chain_rule_lines[$index]}"
    if ! iptables_line_matches "$rule_line" "-A ${IPTABLES_CHAIN}" "-p tcp" "-s ${TAILSCALE_SUBNET}" "--dport ${port}" "-j ACCEPT"; then
      verify_fail "tcp/${port} rule does not match the expected ${TAILSCALE_SUBNET} restriction"
      return 1
    fi
    verify_pass "tcp/${port} is restricted to ${TAILSCALE_SUBNET}"
    index=$((index + 1))
  done

  if [ "${chain_rule_lines[$index]}" = "-A ${IPTABLES_CHAIN} -j DROP" ]; then
    verify_pass "all other inbound IPv4 traffic drops at the end of ${IPTABLES_CHAIN}"
  else
    verify_fail "missing final drop rule in ${IPTABLES_CHAIN}"
    return 1
  fi

  verify_pass "${IPTABLES_CHAIN} rule set matches the repo policy"
}

verify_iptables() {
  local input_rules chain_rules first_input_rule input_jump_count

  input_rules=$(capture_cmd iptables -w -S INPUT) || die "unable to read INPUT chain: ${input_rules:-unknown error}"
  chain_rules=$(capture_cmd iptables -w -S "$IPTABLES_CHAIN") || die "unable to read ${IPTABLES_CHAIN} chain: ${chain_rules:-unknown error}"

  input_jump_count=$(printf '%s\n' "$input_rules" | grep -Fc -- "-A INPUT -j ${IPTABLES_CHAIN}" || true)
  if [ "$input_jump_count" -ne 1 ]; then
    verify_fail "INPUT must jump to ${IPTABLES_CHAIN} exactly once"
    return 1
  fi

  first_input_rule=$(printf '%s\n' "$input_rules" | sed -n '/^-A INPUT /{p;q;}')
  if [ "$first_input_rule" = "-A INPUT -j ${IPTABLES_CHAIN}" ]; then
    verify_pass "${IPTABLES_CHAIN} is the first INPUT rule"
  else
    verify_fail "${IPTABLES_CHAIN} is not the first INPUT rule"
    return 1
  fi

  verify_iptables_chain_rules "$chain_rules"
}

verify_firewall() {
  log_msg "starting firewall verification: ${BACKEND}"

  case "$BACKEND" in
    ufw) verify_ufw ;;
    iptables) verify_iptables ;;
  esac

  log_msg 'firewall verification complete'
}

show_ufw_status() {
  local line

  if [ "$DRY" -eq 1 ]; then
    log_msg 'dry-run: rollback status inspection skipped for ufw'
    return 0
  fi

  while IFS= read -r line; do
    log_msg "ufw status: $line"
  done < <(ufw status verbose 2>&1 || true)
}

show_iptables_status() {
  local line

  if [ "$DRY" -eq 1 ]; then
    log_msg 'dry-run: rollback status inspection skipped for iptables'
    return 0
  fi

  while IFS= read -r line; do
    log_msg "iptables status: $line"
  done < <(iptables -w -S INPUT 2>&1 || true)
}

rollback_ufw() {
  local snapshot="$1"
  local ufw_state='inactive'

  [ -d "$snapshot" ] || die "rollback snapshot is missing: ${snapshot}"
  [ -f "${snapshot}/ufw-state.txt" ] && ufw_state=$(head -n 1 "${snapshot}/ufw-state.txt")

  log_msg "rolling back ufw from snapshot: ${snapshot}"
  restore_snapshot_files "$snapshot"

  if [ "$ufw_state" = 'active' ]; then
    run ufw --force enable
  else
    run ufw --force disable
  fi

  show_ufw_status
}

rollback_iptables() {
  local snapshot="$1"
  local snapshot_file="${snapshot}/iptables.save"

  [ -f "$snapshot_file" ] || die "rollback snapshot is missing ${snapshot_file}"

  log_msg "rolling back iptables from snapshot: ${snapshot}"
  run_input_file "$snapshot_file" iptables-restore
  persist_iptables_rules
  show_iptables_status
}

rollback_snapshot() {
  local snapshot="$1"
  local snapshot_backend

  [ -f "${snapshot}/backend.txt" ] || die "rollback snapshot ${snapshot} is missing backend metadata"
  snapshot_backend=$(head -n 1 "${snapshot}/backend.txt")

  case "$snapshot_backend" in
    ufw) rollback_ufw "$snapshot" ;;
    iptables) rollback_iptables "$snapshot" ;;
    *) die "unsupported backend in rollback snapshot: ${snapshot_backend}" ;;
  esac
}

on_exit() {
  local status=$?

  if [ "$status" -ne 0 ] && [ "$ROLLBACK_ON_ERROR" -eq 1 ] && [ -n "$SNAPSHOT_DIR" ]; then
    ROLLBACK_ON_ERROR=0
    log_msg "firewall apply failed; attempting automatic rollback from ${SNAPSHOT_DIR}"
    if rollback_snapshot "$SNAPSHOT_DIR"; then
      log_msg 'automatic rollback complete'
    else
      log_msg "automatic rollback failed; restore manually from ${SNAPSHOT_DIR}"
    fi
  fi
}

run_apply() {
  detect_backend
  save_rollback_snapshot

  if [ "$DRY" -eq 0 ]; then
    ROLLBACK_ON_ERROR=1
  fi

  case "$BACKEND" in
    ufw) apply_ufw ;;
    iptables) apply_iptables ;;
  esac

  if [ "$DRY" -eq 1 ]; then
    log_msg "dry-run: verification skipped; run $(basename "$0") --backend ${BACKEND} --verify after applying"
    log_msg 'firewall configuration complete'
    return 0
  fi

  verify_firewall
  ROLLBACK_ON_ERROR=0
  log_msg 'firewall configuration complete'
}

run_verify() {
  resolve_backend_for_verify
  log_common_notes
  verify_firewall
}

run_rollback() {
  resolve_snapshot_for_rollback
  log_msg "using rollback snapshot: ${SNAPSHOT_DIR}"
  rollback_snapshot "$SNAPSHOT_DIR"
  log_msg 'firewall rollback complete'
}

main() {
  parse_args "$@"
  ensure_root

  case "$ACTION" in
    apply) run_apply ;;
    verify) run_verify ;;
    rollback) run_rollback ;;
  esac
}

trap on_exit EXIT
main "$@"
