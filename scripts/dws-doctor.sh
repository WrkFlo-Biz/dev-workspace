#!/usr/bin/env bash
set -u
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || { [ -f "$HOME/.config/wrkflo/foundry.env" ] && . "$HOME/.config/wrkflo/foundry.env"; }
ok=0 warn=0 fail=0
c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }
good(){ ok=$((ok+1)); printf '  %s %s\n' "$(c 32 OK)" "$*"; }
meh(){ warn=$((warn+1)); printf '  %s %s\n' "$(c 33 WARN)" "$*"; }
bad(){ fail=$((fail+1)); printf '  %s %s\n' "$(c 31 FAIL)" "$*"; }
sec(){ printf '\n%s\n' "$(c '1;36' "== $1 ==")"; }
have(){ command -v "$1" >/dev/null 2>&1; }
ver(){ case "$1" in tmux) tmux -V 2>/dev/null ;; *) "$1" --version 2>/dev/null | sed -n '1p' ;; esac; }

printf '%s\n' "$(c '1' 'Dev Workspace Doctor')"
sec "Foundry"
if [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then good "Foundry key loaded"; elif [ -f "$HOME/.config/wrkflo/foundry.env" ]; then bad "foundry.env exists but key is not loaded"; else bad "missing ~/.config/wrkflo/foundry.env"; fi

sec "Tailscale"
if ! have tailscale; then
  bad "tailscale CLI missing"
elif tailscale status >/dev/null 2>&1; then
  peers=$(tailscale status --peers 2>/dev/null | awk '$5 != "-" {n++} END{print n+0}')
  good "connected; ${peers} active peer(s)"
else
  bad "tailscale not connected"
fi

sec "Git"
if ! have git; then
  bad "git CLI missing"
else
  repos=0 dirty=0 no_up=0
  for d in "$HOME"/projects/*; do
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    repos=$((repos+1)); n=$(basename "$d"); b=$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$d" rev-parse --short HEAD)
    git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || no_up=$((no_up+1))
    git -C "$d" status --porcelain --ignore-submodules=dirty 2>/dev/null | sed -n '1q' | grep -q . && dirty=$((dirty+1))
    printf '  %-30s %s\n' "$n" "$b"
  done
  [ "$repos" -gt 0 ] && good "checked $repos repos"
  [ "$dirty" -eq 0 ] || meh "$dirty repo(s) dirty"
  [ "$no_up" -eq 0 ] || meh "$no_up repo(s) missing upstream"
fi

sec "Disk"
pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
if [ "$pct" -ge 90 ]; then bad "root disk at ${pct}%"; elif [ "$pct" -ge 80 ]; then meh "root disk at ${pct}%"; else good "root disk at ${pct}%"; fi

sec "Required CLIs"
for cmd in codex claude gh az tmux; do
  if have "$cmd"; then good "$cmd: $(ver "$cmd")"; else bad "$cmd missing"; fi
done

printf '\nSummary: %s ok, %s warn, %s fail\n' "$ok" "$warn" "$fail"
[ "$fail" -eq 0 ]
