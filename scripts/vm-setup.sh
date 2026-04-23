#!/usr/bin/env bash
# vm-setup.sh — idempotent bootstrap for a fresh Ubuntu dev workspace VM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
WRKFLO_CONFIG_DIR="${WRKFLO_CONFIG_DIR:-$HOME/.config/wrkflo}"
CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
ORCHESTRATOR_DIR="${ORCHESTRATOR_DIR:-$PROJECTS_DIR/wrkflo-orchestrator}"
WRKFLO_ORG="${WRKFLO_ORG:-Wrk-Flo}"
WRKFLO_GIT_BASE_URL="${WRKFLO_GIT_BASE_URL:-https://github.com/$WRKFLO_ORG}"

SYSTEM_PACKAGES=(
  tmux
  git
  openssh-client
  curl
  cron
  jq
  iputils-ping
  python3
  python3-venv
  nodejs
  npm
  ca-certificates
  gnupg
  lsb-release
  apt-transport-https
)

WRKFLO_REPOS=(
  global-sentinel
  wrkflo-voice-agents-ops
  openclaw-prod
  global-sentinel-azure-quantum
  wrkflo-orchestrator
  dev-workspace
)

SUMMARY_DONE=()
SUMMARY_SKIPPED=()
SUMMARY_WARNINGS=()
SSH_PUBKEY_PATH=""

APT_UPDATED=0
APT_SOURCES_CHANGED=0

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo)
fi

log() {
  printf '\033[1;34m[vm-setup]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[vm-setup]\033[0m %s\n' "$*" >&2
  SUMMARY_WARNINGS+=("$*")
}

done_item() {
  SUMMARY_DONE+=("$*")
}

skip_item() {
  SUMMARY_SKIPPED+=("$*")
}

run_root() {
  "${SUDO[@]}" "$@"
}

need_sudo() {
  if [ "${#SUDO[@]}" -eq 0 ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  printf 'sudo is required for package installation\n' >&2
  exit 1
}

ensure_apt_update() {
  if [ "$APT_UPDATED" -eq 0 ] || [ "$APT_SOURCES_CHANGED" -eq 1 ]; then
    log "running apt-get update"
    run_root apt-get update -y
    APT_UPDATED=1
    APT_SOURCES_CHANGED=0
  fi
}

ensure_apt_packages() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    skip_item "system packages already present"
    return 0
  fi

  ensure_apt_update
  log "installing system packages: ${missing[*]}"
  run_root apt-get install -y "${missing[@]}"
  done_item "installed system packages: ${missing[*]}"
}

install_apt_keyring() {
  local url="$1"
  local dest="$2"
  local format="${3:-raw}"
  local tmp

  if [ -f "$dest" ]; then
    return 0
  fi

  tmp="$(mktemp)"
  if [ "$format" = "dearmor" ]; then
    curl -fsSL "$url" | gpg --dearmor >"$tmp"
  else
    curl -fsSL "$url" >"$tmp"
  fi
  run_root install -d -m 0755 /etc/apt/keyrings
  run_root install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
}

install_root_file_if_changed() {
  local dest="$1"
  local content="$2"
  local tmp

  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"

  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi

  run_root install -d -m 0755 "$(dirname "$dest")"
  run_root install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

ensure_github_cli() {
  local source_line

  if command -v gh >/dev/null 2>&1; then
    skip_item "GitHub CLI already installed"
    return 0
  fi

  install_apt_keyring \
    "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "/etc/apt/keyrings/githubcli-archive-keyring.gpg"

  source_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
  if install_root_file_if_changed "/etc/apt/sources.list.d/github-cli.list" "$source_line"; then
    APT_SOURCES_CHANGED=1
  fi

  ensure_apt_update
  log "installing GitHub CLI"
  run_root apt-get install -y gh
  done_item "installed GitHub CLI"
}

ensure_azure_cli() {
  local codename source_line

  if command -v az >/dev/null 2>&1; then
    skip_item "Azure CLI already installed"
    return 0
  fi

  codename="$(lsb_release -cs 2>/dev/null || true)"
  if [ -z "$codename" ] && [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  fi
  if [ -z "$codename" ]; then
    printf 'could not determine Ubuntu codename for Azure CLI repo\n' >&2
    exit 1
  fi

  install_apt_keyring \
    "https://packages.microsoft.com/keys/microsoft.asc" \
    "/etc/apt/keyrings/azure-cli.gpg" \
    "dearmor"

  source_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/azure-cli.gpg] https://packages.microsoft.com/repos/azure-cli/ ${codename} main"
  if install_root_file_if_changed "/etc/apt/sources.list.d/azure-cli.list" "$source_line"; then
    APT_SOURCES_CHANGED=1
  fi

  ensure_apt_update
  log "installing Azure CLI"
  run_root apt-get install -y azure-cli
  done_item "installed Azure CLI"
}

ensure_npm_cli() {
  local command_name="$1"
  local package_name="$2"
  local label="$3"

  if command -v "$command_name" >/dev/null 2>&1; then
    skip_item "$label already installed"
    return 0
  fi

  log "installing $label via npm"
  run_root npm install -g "$package_name"
  done_item "installed $label"
}

ensure_directory() {
  local dir="$1"
  if [ -d "$dir" ]; then
    skip_item "directory exists: $dir"
    return 0
  fi
  mkdir -p "$dir"
  done_item "created directory: $dir"
}

copy_if_changed() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  local label="$4"

  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    skip_item "$label already up to date"
    return 0
  fi

  install -m "$mode" "$src" "$dest"
  done_item "$label updated"
}

ensure_ssh_key() {
  local key_base="$HOME/.ssh/id_ed25519"
  local existing_pub=""

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  existing_pub="$(find "$HOME/.ssh" -maxdepth 1 -type f -name '*.pub' | sort | head -1 || true)"
  if [ -n "$existing_pub" ]; then
    SSH_PUBKEY_PATH="$existing_pub"
    skip_item "SSH public key already present: $SSH_PUBKEY_PATH"
    return 0
  fi

  if [ -f "$key_base" ]; then
    log "deriving SSH public key at ${key_base}.pub"
    ssh-keygen -y -f "$key_base" > "${key_base}.pub"
    chmod 644 "${key_base}.pub"
    done_item "derived SSH public key: ${key_base}.pub"
  else
    log "generating SSH key at $key_base"
    ssh-keygen -t ed25519 -N "" -C "${USER}@$(hostname -s 2>/dev/null || hostname)" -f "$key_base" >/dev/null
    done_item "generated SSH key: ${key_base}.pub"
  fi

  SSH_PUBKEY_PATH="${key_base}.pub"
}

codex_profiles_need_merge() {
  local src="$REPO_ROOT/codex-profiles/foundry-profiles.toml"
  local dest="$CODEX_CONFIG_DIR/config.toml"
  local header

  mkdir -p "$CODEX_CONFIG_DIR"
  touch "$dest"

  while IFS= read -r header; do
    [ -n "$header" ] || continue
    if ! grep -Fqx "$header" "$dest"; then
      return 0
    fi
  done < <(grep -E '^\[[^]]+\]$' "$src")

  return 1
}

ensure_codex_profiles() {
  if codex_profiles_need_merge; then
    log "merging Codex Foundry profiles"
    "$REPO_ROOT/scripts/apply-codex-profiles.sh"
    done_item "merged Codex profiles into $CODEX_CONFIG_DIR/config.toml"
  else
    skip_item "Codex profiles already merged"
  fi
}

ensure_cron_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; skipping cron enablement"
    return 0
  fi

  if systemctl is-enabled cron >/dev/null 2>&1 && systemctl is-active cron >/dev/null 2>&1; then
    skip_item "cron service already enabled"
    return 0
  fi

  run_root systemctl enable --now cron
  done_item "enabled cron service"
}

ensure_bash_profile_launcher() {
  local file="$HOME/.bash_profile"
  local clean_file final_file

  touch "$file"
  clean_file="$(mktemp)"
  final_file="$(mktemp)"

  awk '
    BEGIN { skip = 0 }
    $0 == "# >>> dev-workspace launcher >>>" { skip = 1; next }
    $0 == "# <<< dev-workspace launcher <<<" { skip = 0; next }
    !skip { print }
  ' "$file" >"$clean_file"

  cat "$clean_file" >"$final_file"
  if [ -s "$clean_file" ]; then
    printf '\n' >>"$final_file"
  fi
  cat <<'EOF' >>"$final_file"
# >>> dev-workspace launcher >>>
if [ -x "$HOME/bin/dws-launcher.sh" ]; then
  . "$HOME/bin/dws-launcher.sh"
fi
# <<< dev-workspace launcher <<<
EOF

  if cmp -s "$final_file" "$file"; then
    skip_item "~/.bash_profile already sources dws-launcher.sh"
  else
    mv "$final_file" "$file"
    done_item "updated ~/.bash_profile to source dws-launcher.sh"
  fi

  rm -f "$clean_file" "$final_file" 2>/dev/null || true
}

ensure_health_check_cron() {
  local current clean final

  if ! command -v crontab >/dev/null 2>&1; then
    warn "crontab not available; skipping health-check cron"
    return 0
  fi

  current="$(mktemp)"
  clean="$(mktemp)"
  final="$(mktemp)"
  crontab -l 2>/dev/null >"$current" || :

  awk '
    BEGIN { skip = 0 }
    $0 == "# >>> dev-workspace health check >>>" { skip = 1; next }
    $0 == "# <<< dev-workspace health check <<<" { skip = 0; next }
    !skip && index($0, "dws-health-check.sh") == 0 { print }
  ' "$current" >"$clean"

  cat "$clean" >"$final"
  if [ -s "$clean" ]; then
    printf '\n' >>"$final"
  fi
  {
    echo "# >>> dev-workspace health check >>>"
    printf '*/15 * * * * "%s" >/dev/null 2>&1\n' "$BIN_DIR/dws-health-check.sh"
    echo "# <<< dev-workspace health check <<<"
  } >>"$final"

  if cmp -s "$current" "$final"; then
    skip_item "health-check cron already present"
  else
    crontab "$final"
    done_item "installed health-check cron entry"
  fi

  rm -f "$current" "$clean" "$final"
}

clone_repo() {
  local repo="$1"
  local target="$PROJECTS_DIR/$repo"

  if [ -d "$target" ] && git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
    skip_item "repo already cloned: $repo"
    return 0
  fi

  if [ -e "$target" ]; then
    warn "skipping clone for $repo because $target exists and is not a git repo"
    return 0
  fi

  log "cloning $repo into $target"
  if gh auth status >/dev/null 2>&1; then
    gh repo clone "$WRKFLO_ORG/$repo" "$target"
  else
    git clone "$WRKFLO_GIT_BASE_URL/$repo.git" "$target"
  fi
  done_item "cloned repo: $repo"
}

ensure_user_linger() {
  local linger

  if ! command -v loginctl >/dev/null 2>&1; then
    warn "loginctl not available; skipping linger setup"
    return 1
  fi

  linger="$(loginctl show-user "$USER" -p Linger 2>/dev/null || true)"
  if printf '%s\n' "$linger" | grep -q '=yes$'; then
    skip_item "systemd linger already enabled for $USER"
    return 0
  fi

  run_root loginctl enable-linger "$USER"
  done_item "enabled systemd linger for $USER"
}

ensure_orchestrator_systemd() {
  local source_dir="$ORCHESTRATOR_DIR/ops/systemd"
  local units=()
  local src dest unit_name any_units=0 copied_any=0

  if [ ! -d "$source_dir" ]; then
    skip_item "orchestrator systemd units not present"
    return 0
  fi

  mkdir -p "$SYSTEMD_USER_DIR"
  mkdir -p "$HOME/.local/state/wrkflo-orchestrator"

  while IFS= read -r src; do
    [ -n "$src" ] || continue
    any_units=1
    unit_name="$(basename "$src")"
    dest="$SYSTEMD_USER_DIR/$unit_name"
    units+=("$unit_name")
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
      continue
    fi
    install -m 0644 "$src" "$dest"
    copied_any=1
  done < <(find "$source_dir" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.path' \) | sort)

  if [ "$any_units" -eq 0 ]; then
    skip_item "orchestrator systemd directory contains no units"
    return 0
  fi

  ensure_user_linger || true

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    warn "systemctl --user is unavailable; copied orchestrator units but did not enable them"
    return 0
  fi

  systemctl --user daemon-reload
  if [ "$copied_any" -eq 1 ]; then
    done_item "installed orchestrator systemd user units"
  else
    skip_item "orchestrator systemd user units already up to date"
  fi

  for unit_name in "${units[@]}"; do
    if systemctl --user is-enabled "$unit_name" >/dev/null 2>&1 && \
       systemctl --user is-active "$unit_name" >/dev/null 2>&1 && \
       [ "$copied_any" -eq 0 ]; then
      skip_item "systemd unit already enabled: $unit_name"
      continue
    fi

    if systemctl --user enable --now "$unit_name" >/dev/null 2>&1; then
      done_item "enabled and started systemd unit: $unit_name"
    else
      warn "copied $unit_name but could not enable/start it with systemctl --user"
    fi
  done
}

print_summary() {
  printf '\n'
  log "summary"

  if [ "${#SUMMARY_DONE[@]}" -gt 0 ]; then
    printf 'Configured:\n'
    printf '  - %s\n' "${SUMMARY_DONE[@]}"
  else
    printf 'Configured:\n'
    printf '  - no changes needed\n'
  fi

  if [ "${#SUMMARY_SKIPPED[@]}" -gt 0 ]; then
    printf 'Already present:\n'
    printf '  - %s\n' "${SUMMARY_SKIPPED[@]}"
  fi

  if ! gh auth status >/dev/null 2>&1; then
    SUMMARY_WARNINGS+=("GitHub CLI is installed but not authenticated. Run: gh auth login")
  fi
  if ! az account show >/dev/null 2>&1; then
    SUMMARY_WARNINGS+=("Azure CLI is installed but not authenticated. Run: az login")
  fi
  if [ ! -f "$WRKFLO_CONFIG_DIR/foundry.env" ]; then
    SUMMARY_WARNINGS+=("Foundry env file is not present at $WRKFLO_CONFIG_DIR/foundry.env")
  fi
  if [ -n "$SSH_PUBKEY_PATH" ]; then
    SUMMARY_WARNINGS+=("SSH public key ready at $SSH_PUBKEY_PATH")
  fi

  if [ "${#SUMMARY_WARNINGS[@]}" -gt 0 ]; then
    printf 'Notes:\n'
    printf '  - %s\n' "${SUMMARY_WARNINGS[@]}"
  fi
}

main() {
  need_sudo

  ensure_directory "$PROJECTS_DIR"
  ensure_directory "$BIN_DIR"
  ensure_directory "$WRKFLO_CONFIG_DIR"
  ensure_directory "$CODEX_CONFIG_DIR"

  ensure_apt_packages "${SYSTEM_PACKAGES[@]}"
  ensure_github_cli
  ensure_azure_cli
  ensure_npm_cli codex "@openai/codex" "Codex CLI"
  ensure_npm_cli claude "@anthropic-ai/claude-code" "Claude Code"
  ensure_cron_service
  ensure_ssh_key

  local repo
  for repo in "${WRKFLO_REPOS[@]}"; do
    clone_repo "$repo"
  done

  copy_if_changed "$REPO_ROOT/config/tmux.conf" "$HOME/.tmux.conf" 0644 "~/.tmux.conf"
  copy_if_changed "$REPO_ROOT/scripts/dws-launcher.sh" "$BIN_DIR/dws-launcher.sh" 0755 "~/bin/dws-launcher.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-health.sh" "$BIN_DIR/dws-health.sh" 0755 "~/bin/dws-health.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-health-check.sh" "$BIN_DIR/dws-health-check.sh" 0755 "~/bin/dws-health-check.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-notify.sh" "$BIN_DIR/dws-notify.sh" 0755 "~/bin/dws-notify.sh"
  ensure_codex_profiles
  ensure_bash_profile_launcher
  ensure_health_check_cron
  ensure_orchestrator_systemd
  print_summary
}

main "$@"
