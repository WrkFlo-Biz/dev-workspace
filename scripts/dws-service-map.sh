#!/usr/bin/env bash
set -euo pipefail

REPO_UNITS=(
  dws-sessions-init.service
  dws-safe-mode.service
)
OPTIONAL_UNITS=(
  wrkflo-orchestrator-api.service
  dws-task-monitor.service
)
UNITS=()

usage() {
  cat <<'EOF'
usage: dws-service-map.sh

Show the current user-systemd boot order, dependency tree, and runtime state for:
  - dws-sessions-init.service
  - dws-safe-mode.service

Optional host-local units such as `wrkflo-orchestrator-api.service` and the
legacy `dws-task-monitor.service` are included when installed.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

say() {
  printf '%s\n' "$*"
}

unit_value() {
  local unit="$1" property="$2" value

  value=$(systemctl --user show "$unit" --property="$property" --value 2>/dev/null || true)
  printf '%s\n' "$value" | sed -n '1p'
}

has_word() {
  local haystack="$1" needle="$2" item

  for item in $haystack; do
    [ "$item" = "$needle" ] && return 0
  done

  return 1
}

print_word_list() {
  local label="$1" value="$2" item printed=0

  say "  ${label}:"
  for item in $value; do
    say "    - ${item}"
    printed=1
  done

  if [ "$printed" -eq 0 ]; then
    say "    - (none)"
  fi
}

print_dependency_tree() {
  local unit="$1" tree

  say "  dependency-tree:"
  tree=$(systemctl --user list-dependencies --plain "$unit" 2>/dev/null || true)
  if [ -z "$tree" ]; then
    say "    (unavailable)"
    return 0
  fi

  printf '%s\n' "$tree" | sed 's/^/    /'
}

print_critical_chain() {
  local unit="$1" chain

  say "  critical-chain:"
  if ! have systemd-analyze; then
    say "    (systemd-analyze not available)"
    return 0
  fi

  chain=$(systemd-analyze --user critical-chain "$unit" 2>/dev/null | sed '1,2d' || true)
  if [ -z "$chain" ]; then
    say "    (unavailable)"
    return 0
  fi

  printf '%s\n' "$chain" | sed 's/^/    /'
}

require_user_systemd() {
  have systemctl || die 'systemctl is required'
  systemctl --user show default.target >/dev/null 2>&1 || die 'systemctl --user is unavailable'
}

unit_exists() {
  local load_state

  load_state=$(unit_value "$1" LoadState)
  case "$load_state" in
    ''|not-found) return 1 ;;
    *) return 0 ;;
  esac
}

build_unit_list() {
  local unit

  UNITS=("${REPO_UNITS[@]}")

  for unit in "${OPTIONAL_UNITS[@]}"; do
    if unit_exists "$unit"; then
      UNITS+=("$unit")
    fi
  done
}

print_boot_order_summary() {
  local sessions_wanted_by safe_mode_wanted_by safe_mode_conflicts

  sessions_wanted_by=$(unit_value dws-sessions-init.service WantedBy)
  safe_mode_wanted_by=$(unit_value dws-safe-mode.service WantedBy)
  safe_mode_conflicts=$(unit_value dws-safe-mode.service Conflicts)

  say 'Boot Order Summary'
  if has_word "$sessions_wanted_by" default.target; then
    say '  default.target wants dws-sessions-init.service'
  else
    say '  default.target does not currently want dws-sessions-init.service'
  fi

  if has_word "$safe_mode_wanted_by" default.target; then
    say '  default.target wants dws-safe-mode.service'
  else
    say '  default.target does not currently want dws-safe-mode.service'
  fi

  if has_word "$safe_mode_conflicts" dws-sessions-init.service; then
    say '  conflict edge: dws-safe-mode.service <-> dws-sessions-init.service'
  else
    say '  conflict edge: no direct dws-safe-mode.service <-> dws-sessions-init.service relation detected'
  fi

  if unit_exists wrkflo-orchestrator-api.service; then
    say '  optional control plane: wrkflo-orchestrator-api.service installed'
  else
    say '  optional control plane: wrkflo-orchestrator-api.service not installed'
  fi

  if unit_exists dws-task-monitor.service; then
    say '  legacy monitor: dws-task-monitor.service still present on this host'
  else
    say '  legacy monitor: no repo-managed dws-task-monitor.service present'
  fi
}

print_unit_section() {
  local unit="$1"
  local load_state active_state sub_state unit_file_state result fragment_path exec_start
  local after before wants requires wanted_by

  load_state=$(unit_value "$unit" LoadState)
  active_state=$(unit_value "$unit" ActiveState)
  sub_state=$(unit_value "$unit" SubState)
  unit_file_state=$(unit_value "$unit" UnitFileState)
  result=$(unit_value "$unit" Result)
  fragment_path=$(unit_value "$unit" FragmentPath)
  exec_start=$(unit_value "$unit" ExecStart)
  after=$(unit_value "$unit" After)
  before=$(unit_value "$unit" Before)
  wants=$(unit_value "$unit" Wants)
  requires=$(unit_value "$unit" Requires)
  wanted_by=$(unit_value "$unit" WantedBy)

  say
  say "$unit"
  say "  load-state:  ${load_state:-unknown}"
  say "  active:      ${active_state:-unknown} (${sub_state:-unknown})"
  say "  enabled:     ${unit_file_state:-unknown}"
  say "  result:      ${result:-unknown}"
  say "  fragment:    ${fragment_path:-unknown}"
  say "  execstart:   ${exec_start:-unknown}"
  print_word_list 'after' "$after"
  print_word_list 'before' "$before"
  print_word_list 'wants' "$wants"
  print_word_list 'requires' "$requires"
  print_word_list 'wanted-by' "$wanted_by"
  print_dependency_tree "$unit"
  print_critical_chain "$unit"
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
      exit 1
      ;;
  esac

  require_user_systemd
  build_unit_list

  say 'DWS Service Map'
  say "host: $(hostname -s 2>/dev/null || hostname)"
  say "time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  say
  print_boot_order_summary

  for unit in "${UNITS[@]}"; do
    print_unit_section "$unit"
  done
}

main "$@"
