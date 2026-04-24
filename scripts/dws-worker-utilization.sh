#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${DWS_WORKER_UTILIZATION_LOG:-/var/log/dws/monitor.log}"
OUTPUT_MODE="text"

usage() {
  cat <<'USAGE'
usage: dws-worker-utilization.sh [--json] [--help]

Parse /var/log/dws/monitor.log and report per-worker utilization:
  - tasks completed
  - rate-limit hits
  - idle time percentage
  - average task duration

Environment:
  DWS_WORKER_UTILIZATION_LOG  Override the monitor log path.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

format_duration() {
  local value="${1:-}"
  local total hours mins secs

  case "$value" in
    ''|-1|null) printf 'n/a'; return 0 ;;
  esac

  total=$(printf '%.0f' "$value")
  if [ "$total" -lt 0 ]; then
    printf 'n/a'
    return 0
  fi

  hours=$((total / 3600))
  mins=$(((total % 3600) / 60))
  secs=$((total % 60))

  if [ "$hours" -gt 0 ]; then
    printf '%d:%02d:%02d' "$hours" "$mins" "$secs"
  elif [ "$mins" -gt 0 ]; then
    printf '%dm%02ds' "$mins" "$secs"
  else
    printf '%ds' "$secs"
  fi
}

collect_stats() {
  awk '
    function parse_time(ts,    parts, total) {
      split(ts, parts, ":")
      total = (parts[1] * 3600) + (parts[2] * 60) + parts[3] + day_offset
      if (have_prev && total < prev_time) {
        day_offset += 86400
        total += 86400
      }
      prev_time = total
      have_prev = 1
      return total
    }

    function track_worker(name) {
      if (name != "") {
        workers[name] = 1
      }
    }

    {
      if ($0 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] \[monitor\] /) {
        next
      }

      ts = substr($0, 1, 8)
      now = parse_time(ts)
      line = substr($0, 20)

      if (line ~ /^dispatching to [A-Za-z0-9_-]+ /) {
        split(line, parts, " ")
        worker = parts[3]
        track_worker(worker)
        active_start[worker] = now
        next
      }

      if (line ~ /^relaunching [A-Za-z0-9_-]+ /) {
        split(line, parts, " ")
        worker = parts[2]
        track_worker(worker)
        delete active_start[worker]
        next
      }

      split_point = index(line, ": ")
      if (!split_point) {
        next
      }

      worker = substr(line, 1, split_point - 1)
      msg = substr(line, split_point + 2)

      if (worker !~ /^(dws-[A-Za-z0-9_-]+|worker-[A-Za-z0-9_-]+|orchestrator|claude-sync)$/) {
        next
      }

      track_worker(worker)

      if (msg == "marked previous task completed") {
        completed[worker] += 1
        if (worker in active_start) {
          duration = now - active_start[worker]
          if (duration >= 0) {
            duration_sum[worker] += duration
            duration_count[worker] += 1
          }
          delete active_start[worker]
        }
        next
      }

      if (msg == "idle") {
        sample_total[worker] += 1
        idle_samples[worker] += 1
        next
      }

      if (msg == "working (ok)") {
        sample_total[worker] += 1
        next
      }

      if (msg == "rate limited, will retry next cycle") {
        sample_total[worker] += 1
        rate_limit_hits[worker] += 1
        next
      }

      if (msg ~ /FAILED to start/ || msg ~ /relaunch may have failed/) {
        delete active_start[worker]
        next
      }
    }

    END {
      for (worker in workers) {
        idle_pct = sample_total[worker] ? (idle_samples[worker] * 100.0) / sample_total[worker] : 0
        avg_duration = duration_count[worker] ? duration_sum[worker] / duration_count[worker] : -1
        printf "%s\t%d\t%d\t%.1f\t%.1f\n", worker, completed[worker] + 0, rate_limit_hits[worker] + 0, idle_pct, avg_duration
      }
    }
  ' "$LOG_PATH"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      OUTPUT_MODE="json"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[ -r "$LOG_PATH" ] || die "monitor log not readable: $LOG_PATH"

mapfile -t rows < <(collect_stats | LC_ALL=C sort -t "$(printf '\t')" -k1,1)

if [ "$OUTPUT_MODE" = "json" ]; then
  printf '[\n'
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r worker completed rate_limit idle_pct avg_duration <<<"${rows[$i]}"
    if [ "$avg_duration" = "-1.0" ]; then
      avg_seconds='null'
      avg_human='null'
    else
      avg_seconds=$(printf '%.1f' "$avg_duration")
      avg_human=$(printf '"%s"' "$(json_escape "$(format_duration "$avg_seconds")")")
    fi
    printf '  {"worker":"%s","tasks_completed":%s,"rate_limit_hits":%s,"idle_time_percentage":%s,"average_task_duration_seconds":%s,"average_task_duration":%s}' \
      "$(json_escape "$worker")" \
      "$completed" \
      "$rate_limit" \
      "$(printf '%.1f' "$idle_pct")" \
      "$avg_seconds" \
      "$avg_human"
    if [ "$i" -lt $((${#rows[@]} - 1)) ]; then
      printf ','
    fi
    printf '\n'
  done
  printf ']\n'
  exit 0
fi

printf '%-14s %16s %16s %12s %18s\n' "worker" "tasks_completed" "rate_limit_hits" "idle_time%" "avg_task_duration"
printf '%-14s %16s %16s %12s %18s\n' "------" "---------------" "---------------" "----------" "-----------------"
for row in "${rows[@]}"; do
  IFS=$'\t' read -r worker completed rate_limit idle_pct avg_duration <<<"$row"
  printf '%-14s %16s %16s %11s%% %18s\n' \
    "$worker" \
    "$completed" \
    "$rate_limit" \
    "$(printf '%.1f' "$idle_pct")" \
    "$(format_duration "$avg_duration")"
done
