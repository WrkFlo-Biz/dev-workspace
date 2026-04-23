#!/usr/bin/env bash
set -euo pipefail

DIR="${CODEX_PROFILES_DIR:-$HOME/.config/codex/profiles}"
CONFIG="${CODEX_CONFIG_FILE:-$HOME/.codex/config.toml}"
REQ=(foundry-5_4 foundry-5_2 foundry-codex foundry-mini foundry-5-mini foundry-4o foundry-opus foundry-sonnet foundry-haiku)

path() { printf '%s/%s.toml\n' "$DIR" "${1%.toml}"; }
have_dir_profiles() { compgen -G "$DIR/*.toml" >/dev/null; }
have_config_profiles() { [ -f "$CONFIG" ] && grep -q '^\[profiles\.' "$CONFIG"; }
config_names() { awk '/^\[profiles\./{n=$0; sub(/^\[profiles\./,"",n); sub(/\]$/,"",n); print n}' "$CONFIG"; }
config_model() { awk -v t="$1" '
  /^\[profiles\./{n=$0; sub(/^\[profiles\./,"",n); sub(/\]$/,"",n); hit=(n==t); next}
  hit && /^model *= *"/{sub(/^model *= *"/,""); sub(/".*/,""); print; exit}
' "$CONFIG"; }
show_from_config() { awk -v t="$1" '
  /^\[/{
    if (on) exit
    n=$0; sub(/^\[profiles\./,"",n); sub(/\]$/,"",n); on=($0 ~ /^\[profiles\./ && n==t)
  }
  on{print}
' "$CONFIG"; }

report_missing() {
  local p miss=(); local -A seen=()
  for p in "$@"; do seen["$p"]=1; done
  for p in "${REQ[@]}"; do [ "${seen[$p]:-0}" = 1 ] || miss+=("$p"); done
  [ "${#miss[@]}" -eq 0 ] && echo "all 9 expected profiles present" || printf 'missing: %s\n' "${miss[*]}"
}

list_profiles() {
  local any=0 f name model found=()
  mkdir -p "$DIR"
  if have_dir_profiles; then
    for f in "$DIR"/*.toml; do
      [ -e "$f" ] || continue
      any=1; name=${f##*/}; name=${name%.toml}; found+=("$name")
      model=$(sed -n 's/^model *= *"\(.*\)"/\1/p' "$f" | head -1)
      printf '%-18s %s\n' "$name" "${model:-?}"
    done
  elif have_config_profiles; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      any=1; found+=("$name")
      printf '%-18s %s\n' "$name" "$(config_model "$name")"
    done < <(config_names)
  fi
  [ "$any" -eq 1 ] || echo "no installed profiles"
  report_missing "${found[@]}"
}

show_profile() {
  local f; f=$(path "${1:-}")
  if [ -f "$f" ]; then cat "$f"; return; fi
  if have_config_profiles; then show_from_config "$1"; return; fi
  echo "missing: $f" >&2; exit 1
}

edit_profile() {
  mkdir -p "$DIR"
  if have_dir_profiles || [ ! -f "$CONFIG" ]; then "${EDITOR:-vi}" "$(path "${1:-}")"; else "${EDITOR:-vi}" "$CONFIG"; fi
}

case "${1:-}" in
  list) list_profiles ;;
  show) [ -n "${2:-}" ] || { echo "usage: dws-profile show <name>" >&2; exit 1; }; show_profile "$2" ;;
  edit) [ -n "${2:-}" ] || { echo "usage: dws-profile edit <name>" >&2; exit 1; }; edit_profile "$2" ;;
  *) echo "usage: dws-profile {list|show <name>|edit <name>}" >&2; exit 1 ;;
esac
