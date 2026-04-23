#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
PROJECTS_ROOT="${HOME}/projects"
MONITOR_LOG="${DWS_MONITOR_LOG:-/tmp/monitor-log.txt}"
TMUX_SOCKET="${DWS_TMUX_SOCKET:-}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dws-session-meta.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }
have_tmux() { command -v tmux >/dev/null 2>&1; }
is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

single_line() {
  printf '%s' "${1:-}" | tr '\r\n|' '   ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

short_text() {
  local text
  text=$(single_line "${1:-}")
  printf '%.96s' "$text"
}

usage() {
  cat <<EOF
usage: $(basename "$0") [list|show [name]|recover [name]|relaunch [name]|reconnect [name]|kill <name>|kill-all|cleanup|--help]

Commands:
  list       show sessions with recovery state and last known task
  show       show detailed recovery info for one session
  recover    relaunch the most recent recoverable session, or a named session
  relaunch   start a fresh quick-launch session for the same project/profile
  reconnect  attach to the most recent session, or a named session
  kill       kill one session
  kill-all   kill all sessions
  cleanup    kill sessions older than 24h
EOF
}

shell_name() {
  case "${1:-}" in
    bash|sh|zsh|fish|dash|ksh) return 0 ;;
    *) return 1 ;;
  esac
}

proj_short() {
  case "${1:-}" in
    global-sentinel|gs) echo "gs" ;;
    wrkflo-voice-agents-ops|voice) echo "voice" ;;
    openclaw-prod|oclaw) echo "oclaw" ;;
    global-sentinel-azure-quantum|gsaq) echo "gsaq" ;;
    wrkflo-orchestrator|orch) echo "orch" ;;
    dev-workspace|dws) echo "dws" ;;
    *) echo "${1:-?}" ;;
  esac
}

model_label() {
  case "${1:-}" in
    1|5.4|5-4|5_4|foundry-5_4) echo "5-4" ;;
    2|5.2|5-2|5_2|foundry-5_2) echo "5-2" ;;
    3|codex|foundry-codex) echo "codex" ;;
    4|mini|foundry-mini) echo "mini" ;;
    5|5mini|5-mini|foundry-5-mini) echo "5mini" ;;
    6|4o|foundry-4o) echo "4o" ;;
    7|opus|foundry-opus) echo "opus" ;;
    8|sonnet|foundry-sonnet) echo "sonnet" ;;
    9|haiku|foundry-haiku) echo "haiku" ;;
    c|C|claude) echo "claude" ;;
    '') echo "-" ;;
    *) echo "${1:-?}" ;;
  esac
}

tmux_q() {
  if [ -n "$TMUX_SOCKET" ]; then
    tmux -L "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

session_set_option() {
  local session="${1:-}" option="${2:-}" value="${3:-}"
  [ -n "$session" ] || return 1
  [ -n "$option" ] || return 1
  tmux_q set-option -t "$session" -q "$option" "$value" >/dev/null 2>&1 || true
}

persist_session_metadata() {
  local session="${1:-}" project="${2:-}" model="${3:-}" profile="${4:-}" task="${5:-}"
  [ -n "$session" ] || return 1

  case "$project" in ''|'-'|'?') project="" ;; esac
  case "$model" in ''|'-'|'?') model="" ;; esac
  case "$profile" in ''|'-'|'?') profile="" ;; esac
  case "$task" in ''|'-'|'?') task="" ;; esac

  dws_session_meta_write "$session" "$project" "$model" "$profile" "$task" >/dev/null 2>&1 || true
  [ -n "$project" ] && session_set_option "$session" @dws_project "$project"
  [ -n "$model" ] && session_set_option "$session" @dws_model "$model"
  [ -n "$profile" ] && session_set_option "$session" @dws_profile "$profile"
  [ -n "$task" ] && session_set_option "$session" @dws_task "$task"
}

clear_session_metadata() {
  local session="${1:-}"
  [ -n "$session" ] || return 1
  dws_session_meta_clear "$session" >/dev/null 2>&1 || true
}

session_names() {
  tmux_q list-sessions -F '#{session_name}' 2>/dev/null
}

session_exists() {
  tmux_q has-session -t "$1" 2>/dev/null
}

session_pick() {
  local pick="${1:-}" name
  [ -n "$pick" ] || return 1
  if session_exists "$pick"; then
    printf '%s\n' "$pick"
    return 0
  fi
  case "$pick" in
    ''|*[!0-9]*) return 1 ;;
    *)
      name=$(session_names | sed -n "${pick}p")
      [ -n "$name" ] || return 1
      printf '%s\n' "$name"
      ;;
  esac
}

attach_session() {
  if [ -n "${TMUX:-}" ]; then
    tmux_q switch-client -t "$1"
  else
    exec tmux_q attach -t "$1"
  fi
}

fmt_time() {
  local raw="${1:-0}"
  is_int "$raw" || { printf '%s\n' "-"; return; }
  [ "$raw" -gt 0 ] || { printf '%s\n' "-"; return; }
  date -d "@$raw" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$raw" '+%Y-%m-%d %H:%M'
}

session_option() {
  tmux_q show-options -qv -t "$1" "$2" 2>/dev/null || true
}

capture_pane() {
  local target="${1:-}"
  [ -n "$target" ] || return 0
  tmux_q capture-pane -p -t "$target" -S -200 2>/dev/null | tr -d '\r'
}

capture_crash_reason() {
  printf '%s\n' "${1:-}" | awk '
    {
      lines[++n] = tolower($0)
    }
    END {
      start = (n > 25 ? n - 25 + 1 : 1)
      for (i = n; i >= start; i--) {
        if (index(lines[i], "compact error") > 0) {
          print "compact error"
          exit
        }
        if (index(lines[i], "compact task") > 0) {
          print "compact task"
          exit
        }
        if (index(lines[i], "high demand") > 0) {
          print "high demand"
          exit
        }
        if (index(lines[i], "connection closed") > 0) {
          print "connection closed"
          exit
        }
        if (index(lines[i], "session ended") > 0) {
          print "session ended"
          exit
        }
      }
    }'
}

capture_last_task() {
  printf '%s\n' "${1:-}" | awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = trim($0)
      if (line == "") next
      lines[++n] = line
    }
    END {
      for (i = n; i >= 1; i--) {
        line = lines[i]
        lower = tolower(line)
        if (line ~ /^[^[:space:]]+@[^[:space:]]+[:].*[#$]$/) continue
        if (lower ~ /^session ended/) continue
        if (lower ~ /compact error/) continue
        if (lower ~ /compact task/) continue
        if (lower ~ /high demand/) continue
        if (lower ~ /connection closed/) continue
        if (line ~ /^logout$/) continue
        if (line ~ /^Summary \(/) continue
        print substr(line, 1, 96)
        exit
      }
    }'
}

monitor_info() {
  local session="$1"
  [ -r "$MONITOR_LOG" ] || return 0
  awk -v session="$session" '
    function clean(s) {
      gsub(/\r/, "", s)
      gsub(/\|/, "/", s)
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ /, "", s)
      sub(/ $/, "", s)
      return s
    }
    {
      line = $0

      if (match(line, /dispatching to [^ :]+/)) {
        worker = substr(line, RSTART + 15, RLENGTH - 15)
        if (worker == session) {
          rest = substr(line, RSTART + RLENGTH)
          task_text = ""
          if (match(rest, /^ \(repo=[^)]+\): /)) {
            repo_text = substr(rest, RSTART, RLENGTH)
            sub(/^ \(repo=/, "", repo_text)
            sub(/\): $/, "", repo_text)
            repo = clean(repo_text)
            task_text = substr(rest, RLENGTH + 1)
          } else if (match(rest, /^: /)) {
            task_text = substr(rest, 3)
          }
          task_text = clean(task_text)
          if (task_text != "") {
            task = task_text
          }
        }
      }

      if (match(line, /relaunching [^ ]+ \(repo: [^)]+\)/)) {
        worker = substr(line, RSTART + 12, RLENGTH - 12)
        sub(/ .*/, "", worker)
        if (worker == session) {
          repo_text = substr(line, RSTART, RLENGTH)
          sub(/^.*\(repo: /, "", repo_text)
          sub(/\)$/, "", repo_text)
          repo = clean(repo_text)
        }
      }
    }
    END {
      if (repo != "" || task != "") {
        printf "%s|%s\n", repo, task
      }
    }' "$MONITOR_LOG"
}

profile_from_start() {
  local start="${1:-}" value
  case "$start" in
    *"claude --dangerously-skip-permissions"*|*" exec claude "*|claude*) printf '%s\n' "claude"; return 0 ;;
  esac
  value=$(printf '%s\n' "$start" | sed -n 's/.*--profile \([^" ;][^" ;]*\).*/\1/p' | head -1)
  [ -n "$value" ] && printf '%s\n' "$value"
}

project_from_path() {
  local path="${1:-}" rel base
  case "$path" in
    "$PROJECTS_ROOT"/*)
      rel=${path#"$PROJECTS_ROOT"/}
      printf '%s\n' "${rel%%/*}"
      return 0
      ;;
  esac
  base=${path##*/}
  case "$base" in
    global-sentinel|wrkflo-voice-agents-ops|openclaw-prod|global-sentinel-azure-quantum|wrkflo-orchestrator|dev-workspace)
      printf '%s\n' "$base"
      ;;
  esac
}

project_from_start() {
  local start="${1:-}" value
  value=$(
    printf '%s\n' "$start" | sed -n \
      -e "s#.*cd ['\"]\\{0,1\\}$PROJECTS_ROOT/\\([^/'\"; ]*\\).*#\\1#p" \
      -e "s#.*cd ['\"]\\{0,1\\}~/projects/\\([^/'\"; ]*\\).*#\\1#p" \
      -e "s#.*cd ['\"]\\{0,1\\}\\\$HOME/projects/\\([^/'\"; ]*\\).*#\\1#p" \
      | head -1
  )
  [ -n "$value" ] && printf '%s\n' "$value"
}

managed_start() {
  case "${1:-}" in
    *codex*|*claude*) return 0 ;;
    *) return 1 ;;
  esac
}

managed_session() {
  local model="${1:-}" profile="${2:-}" start="${3:-}"
  [ -n "$profile" ] || { [ -n "$model" ] && [ "$model" != "-" ] && [ "$model" != "?" ]; } || managed_start "$start"
}

quick_tool_path() {
  local tool
  for tool in \
    "${REPO_ROOT}/scripts/dws-quick.sh" \
    "${HOME}/projects/dev-workspace/scripts/dws-quick.sh"
  do
    [ -x "$tool" ] || continue
    printf '%s\n' "$tool"
    return 0
  done
  return 1
}

relaunch_info() {
  local project="${1:-}" model="${2:-}" profile="${3:-}"
  local tool short label

  tool=$(quick_tool_path || true)
  short=$(proj_short "$project")
  label=$(model_label "${profile:-$model}")

  [ -n "$tool" ] || return 1
  case "$short" in ''|'?') return 1 ;; esac
  case "$label" in ''|'-'|'?') return 1 ;; esac

  printf '%s|%s|%s|bash %s %s %s\n' "$tool" "$short" "$label" "$tool" "$short" "$label"
}

session_info() {
  local session="$1"
  local created last_attached windows attached project model profile task
  local meta meta_project meta_model meta_profile meta_task meta_updated
  local pane pane_id pane_dead pane_dead_status pane_current pane_start pane_path pane_capture crash_reason
  local state monitor project_from_monitor task_from_monitor

  created=$(tmux_q display-message -p -t "$session" '#{session_created}')
  last_attached=$(tmux_q display-message -p -t "$session" '#{session_last_attached}')
  windows=$(tmux_q display-message -p -t "$session" '#{session_windows}')
  attached=$(tmux_q display-message -p -t "$session" '#{?session_attached,1,0}')
  project=$(session_option "$session" @dws_project)
  model=$(session_option "$session" @dws_model)
  profile=$(session_option "$session" @dws_profile)
  task=$(session_option "$session" @dws_task)

  meta=$(dws_session_meta_read "$session" 2>/dev/null || true)
  IFS='|' read -r meta_project meta_model meta_profile meta_task meta_updated <<EOF
$meta
EOF

  pane=$(tmux_q list-panes -t "$session" -F '#{pane_id}|#{pane_dead}|#{pane_dead_status}|#{pane_current_command}|#{pane_start_command}|#{pane_current_path}' 2>/dev/null | sed -n '1p')
  IFS='|' read -r pane_id pane_dead pane_dead_status pane_current pane_start pane_path <<EOF
$pane
EOF

  pane_capture=$(capture_pane "${pane_id:-$session}")
  crash_reason=$(capture_crash_reason "$pane_capture")
  [ -n "$crash_reason" ] || crash_reason=$(capture_crash_reason "$pane_start")

  monitor=$(monitor_info "$session")
  IFS='|' read -r project_from_monitor task_from_monitor <<EOF
$monitor
EOF

  [ -n "$project" ] || project="${meta_project:-}"
  [ -n "$model" ] || model="${meta_model:-}"
  [ -n "$profile" ] || profile="${meta_profile:-}"
  [ -n "$task" ] || task="${meta_task:-}"
  [ -n "$project" ] || project=$(project_from_path "$pane_path")
  [ -n "$project" ] || project=$(project_from_start "$pane_start")
  [ -n "$project" ] || project="${project_from_monitor:-}"
  [ -n "$profile" ] || profile=$(profile_from_start "$pane_start")
  [ -n "$model" ] || model=$(dws_session_profile_label "$profile")
  [ -n "$model" ] || model=$(model_label "$profile")
  [ -n "${task_from_monitor:-}" ] && task="${task_from_monitor}"
  [ -n "$task" ] || task=$(capture_last_task "$pane_capture")
  [ -n "$task" ] || task=$(short_text "$pane_start")
  [ -n "$task" ] || task="-"

  persist_session_metadata "$session" "$project" "$model" "$profile" "$task"

  if managed_session "$model" "$profile" "$pane_start"; then
    if [ "${pane_dead:-0}" = "1" ] || [ -n "$crash_reason" ]; then
      state="crashed"
    elif shell_name "$pane_current"; then
      state="recover"
    else
      state="active"
    fi
  else
    if [ "${pane_dead:-0}" = "1" ]; then
      state="dead"
    else
      state="plain"
    fi
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$(single_line "$session")" \
    "$(single_line "$state")" \
    "$(single_line "${project:-}")" \
    "$(single_line "${model:-}")" \
    "$(single_line "${profile:-}")" \
    "$(short_text "$task")" \
    "$(single_line "${attached:-0}")" \
    "$(single_line "${created:-0}")" \
    "$(single_line "${last_attached:-0}")" \
    "$(single_line "${windows:-0}")" \
    "$(single_line "${pane_id:-}")" \
    "$(single_line "${pane_dead_status:-}")" \
    "$(short_text "${pane_start:-}")" \
    "$(short_text "${pane_path:-}")" \
    "$(single_line "${crash_reason:-}")"
}

all_infos() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    session_info "$name"
  done < <(session_names)
}

sorted_infos() {
  all_infos | sort -t'|' -k9,9nr -k8,8nr
}

need_sessions() {
  have_tmux || return 1
  session_names >/dev/null 2>&1 || return 1
}

pick_recoverable() {
  local picked
  picked=$(sorted_infos | awk -F'|' '$2 == "recover" || $2 == "crashed" { if ($7 == "0") { print $1; exit } }')
  [ -n "$picked" ] || picked=$(sorted_infos | awk -F'|' '$2 == "recover" || $2 == "crashed" { print $1; exit }')
  [ -n "$picked" ] && printf '%s\n' "$picked"
}

pick_relaunchable() {
  local picked
  picked=$(sorted_infos | awk -F'|' '($3 != "" && $4 != "" && $4 != "-" && $4 != "?") && ($2 == "recover" || $2 == "crashed") { print $1; exit }')
  [ -n "$picked" ] || picked=$(sorted_infos | awk -F'|' '($3 != "" && $4 != "" && $4 != "-" && $4 != "?") { print $1; exit }')
  [ -n "$picked" ] && printf '%s\n' "$picked"
}

list_cmd() {
  local rows
  rows=$(sorted_infos)
  [ -n "$rows" ] || { echo "no tmux sessions"; return 0; }
  printf '%-16s %-8s %-10s %-10s %s\n' "name" "state" "project" "profile" "last-task"
  while IFS='|' read -r name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason; do
    [ -n "$name" ] || continue
    printf '%-16s %-8s %-10s %-10s %s\n' \
      "$name" "$state" "$(proj_short "${project:-${pane_path##*/}}")" "$(model_label "${profile:-$model}")" "$task"
  done <<<"$rows"
  if printf '%s\n' "$rows" | awk -F'|' '$2 == "recover" || $2 == "crashed" { found = 1 } END { exit(found ? 0 : 1) }'; then
    printf '\nrecover in place: %s recover <session>\n' "$(basename "$0")"
  fi
  if pick_relaunchable >/dev/null 2>&1; then
    printf 'one-command relaunch: %s relaunch <session>\n' "$(basename "$0")"
  fi
}

show_cmd() {
  local name info
  local state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason
  local relaunch monitor monitor_project monitor_task

  name=$(session_pick "${1:-}") || die "session not found: ${1:-}"
  info=$(session_info "$name")
  IFS='|' read -r name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason <<EOF
$info
EOF

  monitor=$(monitor_info "$name")
  IFS='|' read -r monitor_project monitor_task <<EOF
$monitor
EOF
  [ -n "$monitor_task" ] || monitor_task="$task"

  relaunch=$(relaunch_info "$project" "$model" "$profile" | awk -F'|' 'NR == 1 { print $4 }')
  printf 'name           %s\n' "$name"
  printf 'state          %s\n' "$state"
  printf 'project        %s\n' "${project:--}"
  printf 'profile        %s\n' "$(model_label "${profile:-$model}")"
  printf 'attached       %s\n' "$([ "$attached" = "1" ] && echo yes || echo no)"
  printf 'created        %s\n' "$(fmt_time "$created")"
  printf 'last attached  %s\n' "$(fmt_time "$last_attached")"
  printf 'windows        %s\n' "$windows"
  printf 'last task      %s\n' "$task"
  if [ -n "$monitor_task" ]; then
    printf 'monitor task   %s\n' "$monitor_task"
  fi
  printf 'path           %s\n' "${pane_path:--}"
  if [ -n "$crash_reason" ]; then
    printf 'crash marker   %s\n' "$crash_reason"
  fi
  printf 'recover        %s recover %s\n' "$(basename "$0")" "$name"
  printf 'one-command    %s relaunch %s\n' "$(basename "$0")" "$name"
  if [ -n "$relaunch" ]; then
    printf 'quick launch   %s\n' "$relaunch"
  fi
  if [ -n "$pane_dead_status" ] && [ "$pane_dead_status" != "0" ]; then
    printf 'exit status    %s\n' "$pane_dead_status"
  fi
}

recover_cmd() {
  local target="${1:-}" info name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason
  local restart

  if [ -n "$target" ]; then
    name=$(session_pick "$target") || die "session not found: $target"
  else
    name=$(pick_recoverable) || die "no recoverable sessions"
  fi

  info=$(session_info "$name")
  IFS='|' read -r name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason <<EOF
$info
EOF

  case "$state" in
    recover|crashed) ;;
    *)
      die "session is not recoverable: $name ($state)"
      ;;
  esac

  restart="$pane_start"
  [ -n "$restart" ] || die "session has no recorded start command: $name"
  [ -n "$pane_id" ] || die "session has no recoverable pane: $name"

  tmux_q respawn-pane -k -t "$pane_id" "$restart" || die "failed to relaunch: $name"
  persist_session_metadata "$name" "$project" "$(model_label "${profile:-$model}")" "$profile" "$task"
  printf 'recovered %s (%s, %s)\n' "$name" "${project:-unknown project}" "$(model_label "${profile:-$model}")"
  printf 'last task: %s\n' "$task"

  if [ -t 0 ] && [ -t 1 ]; then
    attach_session "$name"
  fi
}

relaunch_cmd() {
  local target="${1:-}" info name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason
  local relaunch tool short label command

  if [ -n "$target" ]; then
    name=$(session_pick "$target") || die "session not found: $target"
  else
    name=$(pick_relaunchable) || die "no relaunchable sessions"
  fi

  info=$(session_info "$name")
  IFS='|' read -r name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason <<EOF
$info
EOF

  relaunch=$(relaunch_info "$project" "$model" "$profile") || die "session has no quick relaunch: $name"
  IFS='|' read -r tool short label command <<EOF
$relaunch
EOF

  printf 'relaunching %s -> %s (%s)\n' "$name" "$project" "$label"
  printf 'last task: %s\n' "$task"
  if [ -t 0 ] && [ -t 1 ]; then
    exec bash "$tool" "$short" "$label"
  fi
  printf '%s\n' "$command"
}

reconnect_cmd() {
  local name="${1:-}"
  need_sessions || die "no tmux sessions"
  if [ -n "$name" ]; then
    name=$(session_pick "$name") || die "session not found: $1"
  else
    name=$(sorted_infos | sed -n '1s/|.*//p')
  fi
  [ -n "$name" ] || die "no tmux sessions"
  attach_session "$name"
}

kill_cmd() {
  local name
  need_sessions || die "no tmux sessions"
  name=$(session_pick "${1:-}") || die "session not found: ${1:-}"
  tmux_q kill-session -t "$name" || die "failed to kill: $name"
  clear_session_metadata "$name"
  printf 'killed %s\n' "$name"
}

kill_all_cmd() {
  local name
  need_sessions || { echo "no tmux sessions"; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    tmux_q kill-session -t "$name"
    clear_session_metadata "$name"
  done < <(session_names)
  echo "all sessions killed"
}

cleanup_cmd() {
  local now name created hit=0
  local state project model profile task attached last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason

  need_sessions || { echo "no tmux sessions"; return 0; }
  now=$(date +%s)
  while IFS='|' read -r name state project model profile task attached created last_attached windows pane_id pane_dead_status pane_start pane_path crash_reason; do
    is_int "$created" || continue
    [ $((now - created)) -lt 86400 ] || {
      tmux_q kill-session -t "$name"
      clear_session_metadata "$name"
      hit=1
    }
  done < <(sorted_infos)
  [ "$hit" -eq 1 ] && echo "old sessions cleaned" || echo "no sessions older than 24h"
}

case "${1:-list}" in
  list) list_cmd ;;
  show) shift; show_cmd "${1:-}" ;;
  recover|restart) shift; recover_cmd "${1:-}" ;;
  relaunch) shift; relaunch_cmd "${1:-}" ;;
  reconnect|attach) shift; reconnect_cmd "${1:-}" ;;
  kill) shift; kill_cmd "${1:-}" ;;
  kill-all|killall) kill_all_cmd ;;
  cleanup) cleanup_cmd ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
