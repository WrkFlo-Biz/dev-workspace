#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

LOG_DIR="${DWS_CRON_LOG_DIR:-/var/log/dws}"
HEALTH_SCHEDULE="${DWS_HEALTH_CRON_SCHEDULE:-*/15 * * * *}"
LOG_ROTATE_SCHEDULE="${DWS_LOG_ROTATE_CRON_SCHEDULE:-30 2 * * 0}"
SESSION_CLEANUP_SCHEDULE="${DWS_SESSION_CLEANUP_CRON_SCHEDULE:-0 4 * * *}"
LOG_RETENTION_DAYS="${DWS_LOG_RETENTION_DAYS:-7}"
SESSION_RETENTION_HOURS="${DWS_SESSION_RETENTION_HOURS:-24}"
DISABLED_RETENTION_DAYS="${DWS_DISABLED_RETENTION_DAYS:-365000}"
DISABLED_RETENTION_HOURS="${DWS_DISABLED_RETENTION_HOURS:-876000}"
BLOCK_START="# >>> dev-workspace managed cron >>>"
BLOCK_END="# <<< dev-workspace managed cron <<<"

PASS_COUNT=0
FAIL_COUNT=0
HEALTH_SCRIPT=""
ROTATE_SCRIPT=""
ROTATE_JOB=""
CLEANUP_SCRIPT=""
JOBS=()
JOB_TAGS=()

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s\n' "$*" >&2
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

usage() {
  cat <<'EOF'
usage: dws-cron-setup.sh [--check|--remove|--show|--help]

Installs a managed crontab block for dev-workspace health checks, log
rotation for /var/log/dws, and stale session cleanup. Re-running the installer
keeps the managed entries up to date without duplicating jobs.
EOF
}

resolve_script() {
  local name="$1" candidate

  for candidate in \
    "${SCRIPT_DIR}/${name}" \
    "${REPO_ROOT}/scripts/${name}" \
    "$HOME/bin/${name}"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate=$(command -v "$name" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

ensure_log_dir() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
}

current_crontab() {
  crontab -l 2>/dev/null || true
}

write_crontab() {
  local content="$1" tmp rc=0
  tmp=$(mktemp)

  if [ -n "$content" ]; then
    printf '%s\n' "$content" >"$tmp"
  else
    : >"$tmp"
  fi

  if ! crontab "$tmp"; then
    rc=$?
  fi
  rm -f "$tmp"
  return "$rc"
}

strip_managed_block() {
  awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  '
}

strip_legacy_jobs() {
  awk '
    /^# >>> dev-workspace health check >>>$/ { next }
    /^# <<< dev-workspace health check <<<$/ { next }
    /# dws-(health-check|cleanup|log-rotate|session-cleanup)$/ { next }
    index($0, "dws-health-check.sh") > 0 { next }
    index($0, "dws-rotate-logs.sh") > 0 { next }
    index($0, "dws-cleanup.sh") > 0 { next }
    { print }
  '
}

build_jobs() {
  HEALTH_SCRIPT="${DWS_HEALTH_CHECK_SCRIPT:-$(resolve_script dws-health-check.sh)}"
  CLEANUP_SCRIPT="${DWS_CLEANUP_SCRIPT:-$(resolve_script dws-cleanup.sh)}"

  if [ -n "${DWS_LOG_ROTATE_SCRIPT:-}" ]; then
    ROTATE_SCRIPT="${DWS_LOG_ROTATE_SCRIPT}"
    ROTATE_JOB="\"${ROTATE_SCRIPT}\""
  elif ROTATE_SCRIPT=$(resolve_script dws-rotate-logs.sh 2>/dev/null); then
    ROTATE_JOB="\"${ROTATE_SCRIPT}\""
  else
    ROTATE_SCRIPT="${CLEANUP_SCRIPT}"
    ROTATE_JOB="\"${CLEANUP_SCRIPT}\" --session-hours ${DISABLED_RETENTION_HOURS} --log-days ${LOG_RETENTION_DAYS} --temp-days ${DISABLED_RETENTION_DAYS}"
  fi

  JOB_TAGS=(
    dws-health-check
    dws-log-rotate
    dws-session-cleanup
  )
  JOBS=(
    "${HEALTH_SCHEDULE} \"${HEALTH_SCRIPT}\" >>\"${LOG_DIR}/dws-health-check.cron.log\" 2>&1 # dws-health-check"
    "${LOG_ROTATE_SCHEDULE} ${ROTATE_JOB} >>\"${LOG_DIR}/dws-log-rotate.cron.log\" 2>&1 # dws-log-rotate"
    "${SESSION_CLEANUP_SCHEDULE} \"${CLEANUP_SCRIPT}\" --session-hours ${SESSION_RETENTION_HOURS} --log-days ${LOG_RETENTION_DAYS} --temp-days ${DISABLED_RETENTION_DAYS} >>\"${LOG_DIR}/dws-session-cleanup.cron.log\" 2>&1 # dws-session-cleanup"
  )
}

validate_config() {
  is_int "$LOG_RETENTION_DAYS" || die "DWS_LOG_RETENTION_DAYS must be an integer"
  is_int "$SESSION_RETENTION_HOURS" || die "DWS_SESSION_RETENTION_HOURS must be an integer"
  is_int "$DISABLED_RETENTION_DAYS" || die "DWS_DISABLED_RETENTION_DAYS must be an integer"
  is_int "$DISABLED_RETENTION_HOURS" || die "DWS_DISABLED_RETENTION_HOURS must be an integer"
}

validate_targets() {
  if [ -x "$HEALTH_SCRIPT" ]; then
    pass "health-check target ready: ${HEALTH_SCRIPT}"
  else
    fail "health-check target missing or not executable: ${HEALTH_SCRIPT}"
  fi

  if [ -x "$ROTATE_SCRIPT" ]; then
    pass "log-rotate target ready: ${ROTATE_SCRIPT}"
  else
    fail "log-rotate target missing or not executable: ${ROTATE_SCRIPT}"
  fi

  if [ -x "$CLEANUP_SCRIPT" ]; then
    pass "cleanup target ready: ${CLEANUP_SCRIPT}"
  else
    fail "cleanup target missing or not executable: ${CLEANUP_SCRIPT}"
  fi

  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    pass "cron log dir ready: ${LOG_DIR}"
  elif [ -d "$LOG_DIR" ]; then
    fail "cron log dir is not writable: ${LOG_DIR}"
  else
    fail "cron log dir missing: ${LOG_DIR}"
  fi
}

verify_cron_service() {
  if ! have systemctl; then
    pass "systemctl unavailable; skipped cron service verification"
    return
  fi

  if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
    pass "cron service is active"
  else
    fail "cron service is not active"
  fi
}

print_managed_block() {
  printf '%s\n' "$BLOCK_START"
  printf '%s\n' "${JOBS[@]}"
  printf '%s\n' "$BLOCK_END"
}

install_jobs() {
  local current cleaned desired
  current=$(current_crontab)
  cleaned=$(printf '%s\n' "$current" | strip_managed_block | strip_legacy_jobs)
  desired="$cleaned"
  if [ -n "$desired" ]; then
    desired="${desired}"$'\n'
  fi
  desired="${desired}${BLOCK_START}"$'\n'
  desired="${desired}$(printf '%s\n' "${JOBS[@]}")"$'\n'
  desired="${desired}${BLOCK_END}"
  write_crontab "$desired"
  pass "installed managed dev-workspace cron block"
}

remove_jobs() {
  local current cleaned
  current=$(current_crontab)
  cleaned=$(printf '%s\n' "$current" | strip_managed_block | strip_legacy_jobs)
  write_crontab "$cleaned"
  pass "removed managed dev-workspace cron entries"
}

verify_jobs() {
  local current start_count end_count count idx tag job
  current=$(current_crontab)

  start_count=$(printf '%s\n' "$current" | grep -Fxc "$BLOCK_START" || true)
  end_count=$(printf '%s\n' "$current" | grep -Fxc "$BLOCK_END" || true)
  if [ "$start_count" -eq 1 ] && [ "$end_count" -eq 1 ]; then
    pass "managed cron block present"
  else
    fail "managed cron block markers missing or duplicated"
  fi

  for idx in "${!JOBS[@]}"; do
    tag="${JOB_TAGS[$idx]}"
    job="${JOBS[$idx]}"
    count=$(printf '%s\n' "$current" | grep -Fxc "$job" || true)
    if [ "$count" -eq 1 ]; then
      pass "cron entry installed: ${tag}"
    elif [ "$count" -eq 0 ]; then
      fail "missing cron entry: ${tag}"
    else
      fail "duplicate cron entry: ${tag}"
    fi
  done
}

MODE=install
case "${1:-}" in
  '') ;;
  --check) MODE=check ;;
  --remove) MODE=remove ;;
  --show) MODE=show ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

have crontab || die "crontab is required"
validate_config
build_jobs

case "$MODE" in
  install)
    ensure_log_dir
    validate_targets
    install_jobs
    verify_cron_service
    verify_jobs
    ;;
  check)
    validate_targets
    verify_cron_service
    verify_jobs
    ;;
  remove)
    remove_jobs
    ;;
  show)
    print_managed_block
    ;;
esac

printf 'Summary: %d pass, %d fail\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
