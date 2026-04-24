#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  printf 'error: %s is a source-only helper\n' "$(basename "$0")" >&2
  exit 1
fi

dws_session_meta_dir() {
  local root
  root="${DWS_SESSION_META_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-workspace/session-meta}"
  printf '%s\n' "$root"
}

dws_session_meta_path() {
  local session="${1:-}"
  [ -n "$session" ] || return 1
  printf '%s/%s.tsv\n' "$(dws_session_meta_dir)" "$session"
}

dws_session_meta_clean() {
  printf '%s' "${1:-}" | tr '\r\n\t|' '    ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

dws_session_profile_label() {
  case "${1:-}" in
    1|5.4|5-4|5_4|foundry-5_4) printf '%s\n' "5-4" ;;
    2|5.2|5-2|5_2|foundry-5_2) printf '%s\n' "5-2" ;;
    3|codex|foundry-codex) printf '%s\n' "codex" ;;
    4|mini|foundry-mini) printf '%s\n' "mini" ;;
    5|5mini|5-mini|foundry-5-mini) printf '%s\n' "5mini" ;;
    6|4o|foundry-4o) printf '%s\n' "4o" ;;
    7|opus|foundry-opus) printf '%s\n' "opus" ;;
    8|sonnet|foundry-sonnet) printf '%s\n' "sonnet" ;;
    9|haiku|foundry-haiku) printf '%s\n' "haiku" ;;
    c|C|claude) printf '%s\n' "claude" ;;
    '') printf '%s\n' "" ;;
    *) printf '%s\n' "${1:-}" ;;
  esac
}

dws_session_meta_read() {
  local session="${1:-}" path
  [ -n "$session" ] || return 1
  path=$(dws_session_meta_path "$session") || return 1
  [ -f "$path" ] || return 1
  awk -F '\t' '
    BEGIN {
      project = ""
      model = ""
      profile = ""
      task = ""
      updated_at = ""
    }
    $1 == "project" { project = $2 }
    $1 == "model" { model = $2 }
    $1 == "profile" { profile = $2 }
    $1 == "task" { task = $2 }
    $1 == "updated_at" { updated_at = $2 }
    END {
      printf "%s|%s|%s|%s|%s\n", project, model, profile, task, updated_at
    }
  ' "$path"
}

dws_session_meta_write() {
  local session="${1:-}" project="${2:-}" model="${3:-}" profile="${4:-}" task="${5:-}"
  local path dir tmp now existing existing_project existing_model existing_profile existing_task existing_updated
  [ -n "$session" ] || return 1

  dir=$(dws_session_meta_dir)
  mkdir -p "$dir"
  path=$(dws_session_meta_path "$session") || return 1
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  existing=$(dws_session_meta_read "$session" 2>/dev/null || true)
  IFS='|' read -r existing_project existing_model existing_profile existing_task existing_updated <<EOF
$existing
EOF

  [ -n "$project" ] || project="$existing_project"
  [ -n "$model" ] || model="$existing_model"
  [ -n "$profile" ] || profile="$existing_profile"
  [ -n "$task" ] || task="$existing_task"

  tmp=$(mktemp "${path}.XXXXXX")
  {
    printf 'project\t%s\n' "$(dws_session_meta_clean "$project")"
    printf 'model\t%s\n' "$(dws_session_meta_clean "$model")"
    printf 'profile\t%s\n' "$(dws_session_meta_clean "$profile")"
    printf 'task\t%s\n' "$(dws_session_meta_clean "$task")"
    printf 'updated_at\t%s\n' "$now"
  } >"$tmp"
  mv "$tmp" "$path"
}

dws_session_meta_clear() {
  local session="${1:-}" path
  [ -n "$session" ] || return 1
  path=$(dws_session_meta_path "$session") || return 1
  rm -f "$path"
}
