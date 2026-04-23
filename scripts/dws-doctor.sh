#!/usr/bin/env bash
set -u
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"; }
R=$'\033[31m'; G=$'\033[32m'; C=$'\033[36m'; N=$'\033[0m'; ok=0; fail=0
have(){ command -v "$1" >/dev/null 2>&1; }
pass(){ ok=$((ok+1)); printf '%sPASS%s %s\n' "$G" "$N" "$*"; }
no(){ fail=$((fail+1)); printf '%sFAIL%s %s\n' "$R" "$N" "$*"; }
ver(){ "$1" --version 2>/dev/null | sed -n '1p'; }
cfg_names(){ awk '/^\[profiles\./{n=$0; sub(/^\[profiles\./,"",n); sub(/\]$/,"",n); print n}' "$HOME/.codex/config.toml" 2>/dev/null; }

printf '%sDev Workspace Doctor%s\n' "$C" "$N"
for cmd in codex claude; do
  if have "$cmd"; then pass "$cmd $(ver "$cmd")"; else no "$cmd missing"; fi
done
[ -n "${AZURE_OPENAI_API_KEY:-}" ] && pass "Foundry API key loaded" || no "Foundry API key not loaded"
if have tailscale && tailscale status >/dev/null 2>&1; then pass "Tailscale connected"; else no "Tailscale not connected"; fi
if have gh && gh auth status >/dev/null 2>&1; then pass "gh auth ok"; else no "gh auth missing"; fi
name=$(git config --global user.name 2>/dev/null || true)
[ -n "$name" ] && pass "git user.name set to $name" || no "git user.name missing"
repos=(global-sentinel wrkflo-voice-agents-ops openclaw-prod global-sentinel-azure-quantum wrkflo-orchestrator dev-workspace)
missing=()
for repo in "${repos[@]}"; do [ -d "$HOME/projects/$repo/.git" ] || missing+=("$repo"); done
[ "${#missing[@]}" -eq 0 ] && pass "all 6 repos exist under ~/projects" || no "missing repos: ${missing[*]}"
disk=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5+0}')
[ "$disk" -lt 90 ] && pass "disk ${disk}% used" || no "disk ${disk}% used"
mem=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')
[ "$mem" -lt 90 ] && pass "memory ${mem}% used" || no "memory ${mem}% used"
req=(foundry-5_4 foundry-5_2 foundry-codex foundry-mini foundry-5-mini foundry-4o foundry-opus foundry-sonnet foundry-haiku)
have_profiles=()
while IFS= read -r n; do [ -n "$n" ] && have_profiles+=("$n"); done < <(cfg_names)
missing=()
for p in "${req[@]}"; do
  hit=0; for n in "${have_profiles[@]}"; do [ "$n" = "$p" ] && { hit=1; break; }; done
  [ "$hit" -eq 1 ] || missing+=("$p")
done
[ "${#missing[@]}" -eq 0 ] && pass "all 9 codex profiles exist" || no "missing profiles: ${missing[*]}"
printf '\n%s passed, %s failed\n' "$ok" "$fail"
[ "$fail" -eq 0 ]
