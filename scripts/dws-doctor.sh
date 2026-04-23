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
if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
  pass "Foundry API key loaded"
else
  no "Foundry API key not loaded"
fi
if have tailscale && tailscale status >/dev/null 2>&1; then pass "Tailscale connected"; else no "Tailscale not connected"; fi
if have gh && gh auth status >/dev/null 2>&1; then pass "gh auth ok"; else no "gh auth missing"; fi
name=$(git config --global user.name 2>/dev/null || true)
if [ -n "$name" ]; then
  pass "git user.name set to $name"
else
  no "git user.name missing"
fi
repos=(global-sentinel wrkflo-voice-agents-ops openclaw-prod global-sentinel-azure-quantum wrkflo-orchestrator dev-workspace)
missing=()
for repo in "${repos[@]}"; do [ -d "$HOME/projects/$repo/.git" ] || missing+=("$repo"); done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "all 6 repos exist under ~/projects"
else
  no "missing repos: ${missing[*]}"
fi
disk=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5+0}')
if [ "$disk" -lt 90 ]; then
  pass "disk ${disk}% used"
else
  no "disk ${disk}% used"
fi
mem=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')
if [ "$mem" -lt 90 ]; then
  pass "memory ${mem}% used"
else
  no "memory ${mem}% used"
fi
req=(foundry-5_4 foundry-5_2 foundry-codex foundry-mini foundry-5-mini foundry-4o foundry-opus foundry-sonnet foundry-haiku)
have_profiles=()
while IFS= read -r n; do [ -n "$n" ] && have_profiles+=("$n"); done < <(cfg_names)
missing=()
for p in "${req[@]}"; do
  hit=0; for n in "${have_profiles[@]}"; do [ "$n" = "$p" ] && { hit=1; break; }; done
  [ "$hit" -eq 1 ] || missing+=("$p")
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "all 9 codex profiles exist"
else
  no "missing profiles: ${missing[*]}"
fi
printf '\n%s passed, %s failed\n' "$ok" "$fail"
[ "$fail" -eq 0 ]
