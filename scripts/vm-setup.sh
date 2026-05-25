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
CRON_LOG_DIR="${DWS_CRON_LOG_DIR:-/var/log/dws}"

SYSTEM_PACKAGES=(
  tmux
  git
  openssh-client
  openssh-server
  curl
  cron
  jq
  iputils-ping
  python3
  python3-pip
  python3-venv
  nodejs
  npm
  unattended-upgrades
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

systemd_unit_exists() {
  local unit="$1"
  local load_state=""

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
  [ -n "$load_state" ] && [ "$load_state" != "not-found" ]
}

detect_ssh_service_unit() {
  if systemd_unit_exists "ssh.service"; then
    printf '%s\n' "ssh.service"
    return 0
  fi

  if systemd_unit_exists "sshd.service"; then
    printf '%s\n' "sshd.service"
    return 0
  fi

  return 1
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

ensure_tailscale() {
  local installer

  if command -v tailscale >/dev/null 2>&1; then
    skip_item "Tailscale already installed"
  else
    installer="$(mktemp)"
    log "installing Tailscale"
    curl -fsSL "https://tailscale.com/install.sh" >"$installer"
    run_root sh "$installer"
    rm -f "$installer"
    done_item "installed Tailscale"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; skipping tailscaled enablement"
  elif ! systemd_unit_exists "tailscaled.service"; then
    warn "tailscaled service not found after installation"
  elif systemctl is-enabled tailscaled >/dev/null 2>&1 && systemctl is-active tailscaled >/dev/null 2>&1; then
    skip_item "tailscaled service already enabled"
  else
    run_root systemctl enable --now tailscaled
    done_item "enabled tailscaled service"
  fi

  if command -v tailscale >/dev/null 2>&1 && run_root tailscale status >/dev/null 2>&1; then
    skip_item "Tailscale already authenticated"
  else
    warn "Tailscale is installed but not connected. Run: sudo tailscale up --ssh --operator=$USER --hostname=$(hostname)"
  fi
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
  local src_dir="$REPO_ROOT/config/codex-profiles"
  local dest="$CODEX_CONFIG_DIR/config.toml"
  local header src

  mkdir -p "$CODEX_CONFIG_DIR"
  touch "$dest"

  while IFS= read -r src; do
    while IFS= read -r header; do
      [ -n "$header" ] || continue
      if ! grep -Fqx "$header" "$dest"; then
        return 0
      fi
    done < <(grep -E '^\[[^]]+\]$' "$src")
  done < <(find "$src_dir" -maxdepth 1 -type f -name '*.toml' | sort)

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

ensure_sshd_hardening() {
  local sshd_bin=""
  local ssh_service=""
  local hardening_file="/etc/ssh/sshd_config.d/01-wrkflo-hardening.conf"
  local hardening_content
  local hardening_tmp=""
  local backup=""
  local changed=0

  if [ -x /usr/sbin/sshd ]; then
    sshd_bin="/usr/sbin/sshd"
  elif command -v sshd >/dev/null 2>&1; then
    sshd_bin="$(command -v sshd)"
  else
    warn "sshd not available after package installation; skipping SSH hardening"
    return 0
  fi

  if ! grep -Eq '(ssh-|ecdsa-|sk-)' "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    warn "no SSH authorized_keys entries detected for $USER; verify key or Tailscale SSH access before ending this session"
  fi

  hardening_content="$(cat <<'EOF'
# Managed by dev-workspace/scripts/vm-setup.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 30
ClientAliveCountMax 3
EOF
)"

  hardening_tmp="$(mktemp)"
  printf '%s\n' "$hardening_content" >"$hardening_tmp"

  if [ -f "$hardening_file" ] && cmp -s "$hardening_tmp" "$hardening_file"; then
    rm -f "$hardening_tmp"
    skip_item "sshd hardening already configured"
  else
    if [ -f "$hardening_file" ]; then
      backup="$(mktemp)"
      run_root cp "$hardening_file" "$backup"
    fi

    run_root install -d -m 0755 "$(dirname "$hardening_file")"
    run_root install -m 0644 "$hardening_tmp" "$hardening_file"
    rm -f "$hardening_tmp"

    changed=1
    if ! run_root "$sshd_bin" -t; then
      if [ -n "$backup" ] && [ -f "$backup" ]; then
        run_root install -m 0644 "$backup" "$hardening_file"
      else
        run_root rm -f "$hardening_file"
      fi
      rm -f "$backup"
      printf 'sshd configuration validation failed\n' >&2
      exit 1
    fi
    rm -f "$backup"
    done_item "applied sshd hardening"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; SSH service was not reloaded"
    return 0
  fi

  ssh_service="$(detect_ssh_service_unit || true)"
  if [ -z "$ssh_service" ]; then
    warn "SSH service unit not found; sshd hardening was written but not reloaded"
    return 0
  fi

  if systemctl is-enabled "$ssh_service" >/dev/null 2>&1 && systemctl is-active "$ssh_service" >/dev/null 2>&1; then
    if [ "$changed" -eq 1 ]; then
      if run_root systemctl reload "$ssh_service" >/dev/null 2>&1; then
        done_item "reloaded $ssh_service"
      else
        run_root systemctl restart "$ssh_service"
        done_item "restarted $ssh_service"
      fi
    else
      skip_item "$ssh_service already enabled"
    fi
    return 0
  fi

  run_root systemctl enable --now "$ssh_service"
  done_item "enabled $ssh_service"
}

ensure_automatic_security_updates() {
  local auto_updates_file="/etc/apt/apt.conf.d/20auto-upgrades"
  local unattended_file="/etc/apt/apt.conf.d/52dev-workspace-unattended-upgrades"
  local auto_updates_content
  local unattended_content
  local config_changed=0
  local timers_changed=0
  local timer

  auto_updates_content="$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
)"

  unattended_content="$(cat <<'EOF'
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
)"

  if install_root_file_if_changed "$auto_updates_file" "$auto_updates_content"; then
    config_changed=1
  fi
  if install_root_file_if_changed "$unattended_file" "$unattended_content"; then
    config_changed=1
  fi

  if [ "$config_changed" -eq 1 ]; then
    done_item "configured unattended security updates"
  else
    skip_item "unattended security updates already configured"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; could not verify apt security update timers"
    return 0
  fi

  for timer in apt-daily.timer apt-daily-upgrade.timer; do
    if ! systemd_unit_exists "$timer"; then
      warn "systemd timer not found: $timer"
      continue
    fi

    if systemctl is-enabled "$timer" >/dev/null 2>&1 && systemctl is-active "$timer" >/dev/null 2>&1; then
      continue
    fi

    run_root systemctl enable --now "$timer"
    timers_changed=1
  done

  if [ "$timers_changed" -eq 1 ]; then
    done_item "enabled apt automatic update timers"
  else
    skip_item "apt automatic update timers already enabled"
  fi
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
    skip_item "$HOME/.bash_profile already sources dws-launcher.sh"
  else
    mv "$final_file" "$file"
    done_item "updated $HOME/.bash_profile to source dws-launcher.sh"
  fi

  rm -f "$clean_file" "$final_file" 2>/dev/null || true
}

ensure_cron_log_dir() {
  local group_name

  group_name="$(id -gn)"
  if [ -d "$CRON_LOG_DIR" ] && [ -w "$CRON_LOG_DIR" ]; then
    skip_item "cron log directory already writable: $CRON_LOG_DIR"
    return 0
  fi

  if [ -d "$CRON_LOG_DIR" ]; then
    run_root chown "$USER:$group_name" "$CRON_LOG_DIR"
    run_root chmod 0775 "$CRON_LOG_DIR"
    done_item "updated cron log directory permissions: $CRON_LOG_DIR"
    return 0
  fi

  run_root install -d -o "$USER" -g "$group_name" -m 0775 "$CRON_LOG_DIR"
  done_item "created cron log directory: $CRON_LOG_DIR"
}

ensure_health_check_cron() {
  local current clean final

  if ! command -v crontab >/dev/null 2>&1; then
    warn "crontab not available; skipping health-check cron"
    return 0
  fi

  ensure_cron_log_dir

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
    printf '*/15 * * * * "%s" >>"%s/health-check.log" 2>&1\n' "$BIN_DIR/dws-health-check.sh" "$CRON_LOG_DIR"
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

ensure_openrouter_env() {
  local env_file="$WRKFLO_CONFIG_DIR/openrouter.env"

  if [ -f "$env_file" ]; then
    skip_item "OpenRouter env already present: $env_file"
  else
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      warn "OPENROUTER_API_KEY not set — skipping $env_file. Re-run with OPENROUTER_API_KEY exported."
      return 0
    fi
    mkdir -p "$WRKFLO_CONFIG_DIR"
    printf 'export OPENROUTER_API_KEY="%s"\n' "$OPENROUTER_API_KEY" >"$env_file"
    chmod 600 "$env_file"
    done_item "created $env_file"
  fi

  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if ! grep -q 'wrkflo/openrouter.env' "$rc"; then
      printf '%s\n' "[ -f \"\$HOME/.config/wrkflo/openrouter.env\" ] && . \"\$HOME/.config/wrkflo/openrouter.env\"" >>"$rc"
      done_item "added openrouter.env source to $rc"
    fi
  done
}

ensure_livekit_env() {
  local env_file="$WRKFLO_CONFIG_DIR/livekit.env"

  if [ -f "$env_file" ]; then
    skip_item "LiveKit env already present: $env_file"
  else
    if [ -z "${LIVEKIT_URL:-}" ] || [ -z "${LIVEKIT_API_KEY:-}" ] || [ -z "${LIVEKIT_API_SECRET:-}" ]; then
      warn "LiveKit env vars not set — skipping $env_file. Re-run with LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET exported."
      return 0
    fi
    mkdir -p "$WRKFLO_CONFIG_DIR"
    cat >"$env_file" <<ENV
export LIVEKIT_URL="${LIVEKIT_URL}"
export LIVEKIT_API_KEY="${LIVEKIT_API_KEY}"
export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET}"
ENV
    chmod 600 "$env_file"
    done_item "created $env_file"
  fi

  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if ! grep -q 'wrkflo/livekit.env' "$rc"; then
      printf '%s\n' "[ -f \"\$HOME/.config/wrkflo/livekit.env\" ] && . \"\$HOME/.config/wrkflo/livekit.env\"" >>"$rc"
      done_item "added livekit.env source to $rc"
    fi
  done
}

ensure_livekit_agent() {
  local agent_dir="$REPO_ROOT/workers/eden-voice-agent"
  local venv="$agent_dir/.venv"

  if [ ! -d "$agent_dir" ]; then
    warn "eden-voice-agent worker not found at $agent_dir — skipping"
    return 0
  fi

  if [ -f "$venv/bin/python" ] && systemd_unit_exists "eden-voice-agent.service" 2>/dev/null; then
    skip_item "eden-voice-agent already installed"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found — skipping eden-voice-agent setup"
    return 0
  fi

  log "setting up eden-voice-agent"
  bash "$agent_dir/setup.sh"
  done_item "installed eden-voice-agent (LiveKit voice runtime)"
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
  ensure_tailscale
  ensure_npm_cli codex "@openai/codex" "Codex CLI"
  ensure_npm_cli claude "@anthropic-ai/claude-code" "Claude Code"
  ensure_cron_service
  ensure_ssh_key
  ensure_sshd_hardening
  ensure_automatic_security_updates

  local repo
  for repo in "${WRKFLO_REPOS[@]}"; do
    clone_repo "$repo"
  done

  copy_if_changed "$REPO_ROOT/config/tmux.conf" "$HOME/.tmux.conf" 0644 "$HOME/.tmux.conf"
  copy_if_changed "$REPO_ROOT/scripts/dws-launcher.sh" "$BIN_DIR/dws-launcher.sh" 0755 "$HOME/bin/dws-launcher.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-health.sh" "$BIN_DIR/dws-health.sh" 0755 "$HOME/bin/dws-health.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-health-check.sh" "$BIN_DIR/dws-health-check.sh" 0755 "$HOME/bin/dws-health-check.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-rotate-logs.sh" "$BIN_DIR/dws-rotate-logs.sh" 0755 "$HOME/bin/dws-rotate-logs.sh"
  copy_if_changed "$REPO_ROOT/scripts/dws-notify.sh" "$BIN_DIR/dws-notify.sh" 0755 "$HOME/bin/dws-notify.sh"
  ensure_openrouter_env
  ensure_livekit_env
  ensure_livekit_agent
  ensure_codex_profiles
  ensure_bash_profile_launcher
  ensure_health_check_cron
  ensure_orchestrator_systemd
  print_summary
}

main "$@"
