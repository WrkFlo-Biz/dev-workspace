#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${DWS_LOG_DIR:-/var/log/dws}"
FOLLOW=0
GREP_PATTERN=""
SINCE_SPEC=""
SINCE_TS=""
TAIL_LINES="${DWS_LOG_VIEWER_TAIL_LINES:-40}"

usage() {
  cat <<'EOF'
usage: dws-log-viewer.sh [--follow] [--grep PATTERN] [--since SPEC] [--dir DIR] [--lines N]

View logs under /var/log/dws in one stream.

Options:
  --follow, -f      follow active logs
  --grep PATTERN    filter lines with an extended regular expression
  --since SPEC      only show entries at or after the given time
  --dir DIR         log directory (default: /var/log/dws)
  --lines N         lines per file to preload in follow mode (default: 40)
  -h, --help        show this help

Examples:
  dws-log-viewer.sh
  dws-log-viewer.sh --since '2 hours ago'
  dws-log-viewer.sh --grep 'ERROR|ALERT' --follow
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

have() {
  command -v "$1" >/dev/null 2>&1
}

file_mtime_epoch() {
  local path="$1"

  stat -c '%Y' "$path" 2>/dev/null && return 0
  stat -f '%m' "$path" 2>/dev/null && return 0
  return 1
}

epoch_to_log_ts() {
  local epoch="$1"

  date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
  date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
  return 1
}

parse_since_ts() {
  local spec="$1"

  case "$spec" in
    '' ) return 0 ;;
    *[!0-9]*)
      date -d "$spec" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
      date -j -f '%Y-%m-%d %H:%M:%S' "$spec" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
      date -j -f '%Y-%m-%dT%H:%M:%S' "$spec" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
      date -j -f '%Y-%m-%dT%H:%M:%SZ' "$spec" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
      ;;
    *)
      epoch_to_log_ts "$spec" && return 0
      ;;
  esac

  return 1
}

list_logs() {
  local include_archives="${1:-1}" path mtime

  while IFS= read -r path; do
    case "$(basename -- "$path")" in
      .*|*.tmp|*.lock) continue ;;
    esac

    if [ "$include_archives" -ne 1 ] && [[ "$path" == *.gz ]]; then
      continue
    fi

    mtime=$(file_mtime_epoch "$path" || printf '0')
    printf '%s\t%s\n' "$mtime" "$path"
  done < <(find "$LOG_DIR" -maxdepth 1 -type f | sort)
}

print_file() {
  local path="$1"

  if [[ "$path" == *.gz ]]; then
    gzip -dc -- "$path"
  else
    cat -- "$path"
  fi
}

emit_file_records() {
  local path="$1" order_key="$2" source file_ts

  source=$(basename -- "$path")
  file_ts=$(epoch_to_log_ts "$(file_mtime_epoch "$path" || printf '0')" 2>/dev/null || printf '0000-00-00 00:00:00')

  print_file "$path" | awk \
    -v source="$source" \
    -v order_key="$order_key" \
    -v file_ts="$file_ts" \
    -v since_ts="$SINCE_TS" \
    -v pattern="$GREP_PATTERN" '
      function log_ts(text, raw) {
        raw = ""
        if (match(text, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
          raw = substr(text, RSTART, RLENGTH)
          gsub(/T/, " ", raw)
        }
        return raw
      }

      BEGIN {
        current_ts = file_ts
        line_no = 0
      }

      {
        line_no += 1
        parsed = log_ts($0)
        if (parsed != "") {
          current_ts = parsed
        }

        if (length(since_ts) > 0 && current_ts < since_ts) {
          next
        }

        if (length(pattern) > 0 && $0 !~ pattern) {
          next
        }

        printf "%s\t%s-%09d\t[%s] %s\n", current_ts, order_key, line_no, source, $0
      }
    '
}

render_logs() {
  local path file_index=0

  while IFS=$'\t' read -r _ path; do
    file_index=$((file_index + 1))
    emit_file_records "$path" "$(printf '%09d' "$file_index")"
  done < <(list_logs 1 | sort -n) | sort -s -t $'\t' -k1,1 -k2,2 | awk '
    {
      sub(/^[^\t]*\t[^\t]*\t/, "", $0)
      print
    }
  '
}

stream_follow() {
  local -a files=()
  local path preload_lines

  while IFS=$'\t' read -r _ path; do
    files+=("$path")
  done < <(list_logs 0 | sort -n)

  if [ "${#files[@]}" -eq 0 ]; then
    printf 'no active logs in %s\n' "$LOG_DIR" >&2
    return 0
  fi

  if [ -n "$SINCE_TS" ]; then
    preload_lines='+1'
  else
    preload_lines="$TAIL_LINES"
  fi

  tail -n "$preload_lines" -F -v -- "${files[@]}" 2>/dev/null | awk \
    -v since_ts="$SINCE_TS" \
    -v pattern="$GREP_PATTERN" '
      function log_ts(text, raw) {
        raw = ""
        if (match(text, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
          raw = substr(text, RSTART, RLENGTH)
          gsub(/T/, " ", raw)
        }
        return raw
      }

      function header_source(text, raw) {
        if (match(text, /^==> .* <==$/)) {
          raw = substr(text, 5, length(text) - 8)
          sub(/^.*\//, "", raw)
          return raw
        }
        return ""
      }

      {
        header = header_source($0)
        if (header != "") {
          source = header
          next
        }

        if (source == "") {
          next
        }

        parsed = log_ts($0)
        if (parsed != "") {
          current_ts[source] = parsed
        }

        if (length(since_ts) > 0) {
          if (!(source in current_ts)) {
            next
          }
          if (current_ts[source] < since_ts) {
            next
          }
        }

        if (length(pattern) > 0 && $0 !~ pattern) {
          next
        }

        printf "[%s] %s\n", source, $0
        fflush()
      }
    '
}

main() {
  local path

  while [ $# -gt 0 ]; do
    case "$1" in
      --follow|-f)
        FOLLOW=1
        ;;
      --grep)
        [ $# -ge 2 ] || die "--grep requires a pattern"
        GREP_PATTERN="$2"
        shift
        ;;
      --grep=*)
        GREP_PATTERN="${1#*=}"
        ;;
      --since)
        [ $# -ge 2 ] || die "--since requires a time spec"
        SINCE_SPEC="$2"
        shift
        ;;
      --since=*)
        SINCE_SPEC="${1#*=}"
        ;;
      --dir)
        [ $# -ge 2 ] || die "--dir requires a path"
        LOG_DIR="$2"
        shift
        ;;
      --dir=*)
        LOG_DIR="${1#*=}"
        ;;
      --lines)
        [ $# -ge 2 ] || die "--lines requires a count"
        TAIL_LINES="$2"
        shift
        ;;
      --lines=*)
        TAIL_LINES="${1#*=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown flag: $1"
        ;;
    esac
    shift
  done

  [ -d "$LOG_DIR" ] || die "log directory not found: ${LOG_DIR}"
  is_uint "$TAIL_LINES" || die "--lines must be a non-negative integer"
  have awk || die "required command not found: awk"
  have sort || die "required command not found: sort"

  if [ -n "$SINCE_SPEC" ]; then
    SINCE_TS=$(parse_since_ts "$SINCE_SPEC") || die "could not parse --since value: ${SINCE_SPEC}"
  fi

  if [ "$FOLLOW" -eq 1 ]; then
    have tail || die "required command not found: tail"
    stream_follow
    return 0
  fi

  render_logs
}

main "$@"
