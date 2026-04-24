#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${DWS_BACKUP_ROOT:-$HOME/backups/dev-workspace}"
KEEP_COUNT="${DWS_BACKUP_KEEP_COUNT:-${DWS_BACKUP_KEEP_DAYS:-5}}"
VERIFY_ROOT="${DWS_VERIFY_RESTORE_ROOT:-${TMPDIR:-/tmp}/dws-verify-restore}"
KEEP_VERIFY_DIR="${DWS_VERIFY_RESTORE_KEEP:-0}"
MANIFEST_LEGACY="/tmp/dws-backup-manifest.txt"
TIMESTAMP="${DWS_BACKUP_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
PROJECTS_ROOT="${DWS_PROJECTS_ROOT:-$HOME/projects}"
WRKFLO_CONFIG_DIR="${DWS_WRKFLO_CONFIG_DIR:-$HOME/.config/wrkflo}"
USER_BIN_DIR="${DWS_USER_BIN_DIR:-$HOME/bin}"
SSH_DIR="${DWS_SSH_DIR:-$HOME/.ssh}"

MODE="backup"
DRY_RUN=0
SNAPSHOT_DIR=""
ARCHIVE_PATH=""
RESTORE_TARGET=""
PRUNE_AFTER_VERIFY=0

ARCHIVE_ROOT=""
STAGE_ROOT=""
MANIFEST_LINES=""
REPO_MANIFEST_LINES=""
REPO_COUNT=0
SAVED_COUNT=0
SKIPPED_COUNT=0
RESTORED_COUNT=0
VERIFIED_COUNT=0

usage() {
  cat <<'EOF'
usage: dws-backup.sh [backup|restore|verify-restore|cron] [options] [snapshot|archive]

Commands:
  backup                  create a timestamped tarball and prune older backups
  restore [latest]        extract the selected backup tarball and print restore guidance
  verify-restore [latest] extract into scratch space and verify the archived manifest
  cron                    run backup, then verify the new backup

Options:
  --dry-run               print planned actions without writing files
  --root DIR              backup root directory (default: ~/backups/dev-workspace)
  --keep N                keep the last N backups (default: 5)
  --keep-count N          alias for --keep
  --keep-days N           compatibility alias for --keep
  --target DIR            extraction target for restore
  --verify-root DIR       verify scratch root (default: /tmp/dws-verify-restore)
  --archive PATH          explicit archive path for restore or verify-restore
  --snapshot DIR          explicit snapshot dir for restore or verify-restore
  --prune                 prune old backups after successful verify-restore
  --restore               compatibility alias for restore latest
  --verify-restore        compatibility alias for verify-restore latest
  -h, --help              show this help

Backed up data:
  ~/.config/wrkflo/, ~/bin/, ~/.ssh/
  tmux layouts and user crontab
  git metadata for repos under ~/projects/ (refs, remotes, status, stash patches only)

Environment:
  DWS_BACKUP_KEEP_COUNT=N         number of backups to keep (default: 5)
  DWS_BACKUP_KEEP_DAYS=N          compatibility fallback for DWS_BACKUP_KEEP_COUNT
  DWS_PROJECTS_ROOT=DIR           projects root to scan for git repos
  DWS_VERIFY_RESTORE_ROOT=DIR     scratch root for verify-restore
  DWS_VERIFY_RESTORE_KEEP=1       keep the extracted verify dir after success
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

need() {
  have "$1" || die "required command not found: $1"
}

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

say() {
  printf '%s\n' "$*"
}

validate_nonempty_path() {
  local path="$1" label="$2"
  [ -n "$path" ] || die "${label} path is empty"
}

validate_safe_host_path() {
  local path="$1" label="$2"

  validate_nonempty_path "$path" "$label"

  case "$path" in
    /*) ;;
    *) die "${label} path must be absolute: ${path}" ;;
  esac

  case "$path" in
    /) die "${label} path must not be /" ;;
    ../*|*/../*|*/..|./*|*/./*|*/.) die "${label} path must not contain dot segments: ${path}" ;;
  esac
}

validate_directory_path() {
  local path="$1" label="$2"
  validate_nonempty_path "$path" "$label"
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    die "${label} is not a directory: ${path}"
  fi
}

validate_parent_dir_path() {
  local path="$1" label="$2" parent
  validate_nonempty_path "$path" "$label"
  parent=$(dirname -- "$path")
  if [ -e "$parent" ] && [ ! -d "$parent" ]; then
    die "${label} parent is not a directory: ${parent}"
  fi
}

validate_relative_archive_path() {
  local rel="$1" label="$2"
  case "$rel" in
    ""|/*|../*|*/../*|*/..|..|./*|*/./*|*/.)
      die "unsafe archive path for ${label}: ${rel:-<empty>}"
      ;;
  esac
}

validate_optional_source_dir_path() {
  local path="$1" label="$2"

  validate_safe_host_path "$path" "$label"

  if backupable_source_exists "$path" && [ ! -d "$path" ]; then
    die "${label} is not a directory: ${path}"
  fi
}

backupable_source_exists() {
  local path="$1"
  [ -e "$path" ] || [ -L "$path" ]
}

backupable_source_type() {
  local path="$1"
  if [ -d "$path" ]; then
    printf '%s\n' "dir"
  elif [ -f "$path" ]; then
    printf '%s\n' "file"
  elif [ -L "$path" ]; then
    printf '%s\n' "symlink"
  else
    return 1
  fi
}

cleanup_stage_root() {
  if [ -n "${STAGE_ROOT:-}" ] && [ -d "${STAGE_ROOT}" ]; then
    rm -rf -- "${STAGE_ROOT}"
  fi
}

trap cleanup_stage_root EXIT

archive_basename_for_timestamp() {
  printf 'dws-backup-%s.tar.gz\n' "$1"
}

archive_root_from_path() {
  local name
  name=$(basename -- "$1")
  name=${name%.tar.gz}
  printf '%s\n' "$name"
}

stage_path() {
  validate_relative_archive_path "$1" "stage path"
  printf '%s/%s/%s\n' "$STAGE_ROOT" "$ARCHIVE_ROOT" "$1"
}

write_path() {
  local path="$1" content="$2"
  mkdir -p -- "$(dirname "$path")"
  printf '%s' "$content" >"$path"
}

record_manifest() {
  local rel="$1" label="$2"
  MANIFEST_LINES="${MANIFEST_LINES}${rel}"$'\t'"${label}"$'\n'
  SAVED_COUNT=$((SAVED_COUNT + 1))
}

save_stage_text() {
  local rel="$1" label="$2" content="$3" path
  path=$(stage_path "$rel")
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would write ${label}: ${ARCHIVE_ROOT}/${rel}"
  else
    write_path "$path" "$content"
  fi
  record_manifest "$rel" "$label"
}

write_snapshot_text() {
  local rel="$1" content="$2" path
  validate_relative_archive_path "$rel" "snapshot path"
  path="${SNAPSHOT_DIR}/${rel}"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would write ${path}"
  else
    write_path "$path" "$content"
  fi
}

copy_stage_tree() {
  local src="$1" rel="$2" label="$3" dest_parent src_parent src_name src_type

  validate_nonempty_path "$src" "$label"
  validate_relative_archive_path "$rel" "$label"

  if ! backupable_source_exists "$src"; then
    say "skip ${label}: ${src} missing"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi

  if ! src_type=$(backupable_source_type "$src"); then
    say "skip ${label}: ${src} has unsupported type"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    say "would back up ${label}: ${src} -> ${ARCHIVE_ROOT}/${rel}"
    record_manifest "$rel" "$label"
    return 0
  fi

  dest_parent=$(dirname -- "$(stage_path "$rel")")
  src_parent=$(dirname -- "$src")
  src_name=$(basename -- "$src")
  [ -d "$src_parent" ] || die "source parent missing for ${label}: ${src_parent}"
  mkdir -p -- "$dest_parent"

  if ! (
    cd -- "$src_parent"
    find "./$src_name" \( -type d -o -type f -o -type l \) -print0 |
      tar --null -T - -cf - 2>/dev/null
  ) | tar -C "$dest_parent" -xf -; then
    die "failed to back up ${label}: ${src} (${src_type})"
  fi

  record_manifest "$rel" "$label"
}

latest_snapshot() {
  local path
  [ -d "$BACKUP_ROOT" ] || return 0
  if [ -L "${BACKUP_ROOT}/latest" ]; then
    path=$(readlink -f -- "${BACKUP_ROOT}/latest" 2>/dev/null || true)
    if [ -n "$path" ] && [ -d "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' | sort | tail -1
}

archive_path_for_snapshot() {
  local snapshot="$1" name_file archive_name

  if [ -f "$snapshot/meta/archive-name.txt" ]; then
    archive_name=$(head -n 1 "$snapshot/meta/archive-name.txt")
    if [ -n "$archive_name" ]; then
      printf '%s/%s\n' "$(dirname "$snapshot")" "$archive_name"
      return 0
    fi
  fi

  archive_name=$(archive_basename_for_timestamp "$(basename "$snapshot")")
  if [ -f "$(dirname "$snapshot")/${archive_name}" ]; then
    printf '%s/%s\n' "$(dirname "$snapshot")" "$archive_name"
    return 0
  fi

  return 1
}

resolve_backup_reference() {
  local ref="${SNAPSHOT_DIR:-}"

  if [ -n "$ARCHIVE_PATH" ]; then
    [ -f "$ARCHIVE_PATH" ] || die "archive not found: ${ARCHIVE_PATH}"
    SNAPSHOT_DIR=""
    return 0
  fi

  if [ -z "$ref" ] || [ "$ref" = "latest" ]; then
    ref=$(latest_snapshot)
  fi
  [ -n "$ref" ] || die "no backup snapshot found under ${BACKUP_ROOT}"

  if [ -f "$ref" ]; then
    ARCHIVE_PATH="$ref"
    SNAPSHOT_DIR=""
    return 0
  fi

  [ -d "$ref" ] || die "backup reference not found: ${ref}"
  SNAPSHOT_DIR="$ref"
  ARCHIVE_PATH=$(archive_path_for_snapshot "$SNAPSHOT_DIR") || die "archive path not found for snapshot: ${SNAPSHOT_DIR}"
}

set_latest_symlink() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would refresh latest symlink: ${BACKUP_ROOT}/latest -> ${SNAPSHOT_DIR}"
  else
    ln -sfn -- "$SNAPSHOT_DIR" "${BACKUP_ROOT}/latest"
  fi
}

discover_git_repos() {
  [ -d "$PROJECTS_ROOT" ] || return 0
  find "$PROJECTS_ROOT" -mindepth 1 \( -type d -name .git -o -type f -name .git \) -printf '%h\n' | sort -u
}

repo_rel_path() {
  local repo="$1"
  case "$repo" in
    "${PROJECTS_ROOT}/"*) printf '%s\n' "${repo#"$PROJECTS_ROOT"/}" ;;
    *) basename -- "$repo" ;;
  esac
}

backup_git_repo() {
  local repo="$1" repo_rel base_rel head_ref head_sha remotes refs status stashes
  local stash_count=0 stash_index=0 stash_ref stash_patch summary

  repo_rel=$(repo_rel_path "$repo")
  base_rel="projects-git/${repo_rel}"
  head_ref=$(
    git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null ||
      git -C "$repo" rev-parse --short HEAD 2>/dev/null ||
      printf 'unknown'
  )
  head_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf 'unknown')
  remotes=$(git -C "$repo" remote -v 2>/dev/null || true)
  refs=$(git -C "$repo" for-each-ref --format='%(refname)\t%(objectname)\t%(upstream:short)\t%(HEAD)\t%(subject)' refs/heads refs/remotes refs/tags 2>/dev/null || true)
  status=$(git -C "$repo" status --short --branch 2>/dev/null || true)
  stashes=$(git -C "$repo" stash list --date=iso-strict 2>/dev/null || true)

  while IFS= read -r stash_ref; do
    [ -n "$stash_ref" ] || continue
    stash_patch=$(
      git -C "$repo" stash show --include-untracked -p --binary "$stash_ref" 2>/dev/null ||
        git -C "$repo" stash show -p --binary "$stash_ref" 2>/dev/null ||
        printf '# unable to render patch for %s\n' "$stash_ref"
    )
    save_stage_text \
      "${base_rel}/stash-patches/stash-$(printf '%02d' "$stash_index").patch" \
      "stash patch (${repo_rel} ${stash_ref})" \
      "$stash_patch"
    stash_index=$((stash_index + 1))
    stash_count=$((stash_count + 1))
  done < <(git -C "$repo" stash list --format='%gd' 2>/dev/null || true)

  summary=$(
    cat <<EOF
repo_path=${repo}
relative_path=${repo_rel}
head_ref=${head_ref}
head_sha=${head_sha}
stash_count=${stash_count}
git_repo_backup=refs,remotes,status,stash-patches-only
EOF
  )

  save_stage_text "${base_rel}/summary.txt" "git summary (${repo_rel})" "${summary}"
  save_stage_text "${base_rel}/status.txt" "git status (${repo_rel})" "${status}"
  save_stage_text "${base_rel}/remotes.txt" "git remotes (${repo_rel})" "${remotes}"
  save_stage_text "${base_rel}/refs.tsv" "git refs (${repo_rel})" "${refs}"
  save_stage_text "${base_rel}/stashes.txt" "git stashes (${repo_rel})" "${stashes}"

  REPO_MANIFEST_LINES="${REPO_MANIFEST_LINES}${repo_rel}"$'\t'"${head_ref}"$'\t'"${head_sha}"$'\t'"${stash_count}"$'\n'
  REPO_COUNT=$((REPO_COUNT + 1))
}

backup_git_metadata() {
  local repo

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    backup_git_repo "$repo"
  done < <(discover_git_repos)
}

capture_tmux_layouts() {
  local sessions windows panes note

  if ! have tmux; then
    note=$'tmux is not installed on this host.\n'
    save_stage_text "tmux/README.txt" "tmux note" "$note"
    return 0
  fi

  if ! tmux list-sessions >/dev/null 2>&1; then
    note=$'No tmux server is running, so there were no live layouts to capture.\n'
    save_stage_text "tmux/README.txt" "tmux note" "$note"
    return 0
  fi

  sessions=$(tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created_string}' 2>/dev/null || true)
  windows=$(tmux list-windows -a -F '#{session_name}\t#{window_index}\t#{window_name}\t#{window_layout}\t#{window_active}\t#{window_flags}' 2>/dev/null || true)
  panes=$(tmux list-panes -a -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_width}x#{pane_height}' 2>/dev/null || true)
  note=$'Use layouts.tsv and panes.tsv together to recreate session/window shapes manually.\n'

  save_stage_text "tmux/README.txt" "tmux note" "$note"
  save_stage_text "tmux/sessions.tsv" "tmux sessions" "$sessions"
  save_stage_text "tmux/layouts.tsv" "tmux layouts" "$windows"
  save_stage_text "tmux/panes.tsv" "tmux panes" "$panes"
}

capture_crontab() {
  local crontab_text

  if ! have crontab; then
    crontab_text=$'# crontab command is not available on this host\n'
  elif crontab_text=$(crontab -l 2>/dev/null); then
    :
  else
    crontab_text=$'# no user crontab is installed\n'
  fi

  save_stage_text "system/crontab.txt" "crontab" "${crontab_text}"
}

build_restore_instructions() {
  cat <<EOF
Dev Workspace Restore Instructions

1. Extract the backup tarball somewhere safe:
   mkdir -p ~/restore
   tar -xzf $(basename -- "$ARCHIVE_PATH") -C ~/restore

2. After extraction, the backup contents will be under:
   ~/restore/${ARCHIVE_ROOT}

3. Restore the backed up home data:
   mkdir -p ~/.config/wrkflo && cp -a ~/restore/${ARCHIVE_ROOT}/home/.config/wrkflo/. ~/.config/wrkflo/
   mkdir -p ~/bin && cp -a ~/restore/${ARCHIVE_ROOT}/home/bin/. ~/bin/
   mkdir -p ~/.ssh && chmod 700 ~/.ssh && cp -a ~/restore/${ARCHIVE_ROOT}/home/.ssh/. ~/.ssh/

4. Restore cron if you want the archived user crontab back:
   crontab ~/restore/${ARCHIVE_ROOT}/system/crontab.txt

5. Recreate git repos under ~/projects before using the git metadata backup.
   This backup intentionally stores refs, remotes, status, and stash patches only.
   It does not store full clones or the complete object database for local-only commits.
   Review:
     ~/restore/${ARCHIVE_ROOT}/projects-git/<repo>/summary.txt
     ~/restore/${ARCHIVE_ROOT}/projects-git/<repo>/refs.tsv
     ~/restore/${ARCHIVE_ROOT}/projects-git/<repo>/stash-patches/
   Reapply a saved stash patch with:
     git -C ~/projects/<repo> apply --index <patch-file>

6. Review tmux session metadata and recreate layouts manually from:
   ~/restore/${ARCHIVE_ROOT}/tmux/layouts.tsv
   ~/restore/${ARCHIVE_ROOT}/tmux/panes.tsv
EOF
}

write_metadata() {
  local archive_name restore_instructions summary

  archive_name=$(basename -- "$ARCHIVE_PATH")
  restore_instructions=$(build_restore_instructions)
  save_stage_text "RESTORE.txt" "restore instructions" "$restore_instructions"
  summary=$(
    cat <<EOF
created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
host=$(hostname -s 2>/dev/null || hostname)
backup_root=${BACKUP_ROOT}
snapshot_dir=${SNAPSHOT_DIR}
archive_name=${archive_name}
projects_root=${PROJECTS_ROOT}
repo_count=${REPO_COUNT}
saved_items=${SAVED_COUNT}
skipped_items=${SKIPPED_COUNT}
keep_count=${KEEP_COUNT}
git_repo_backup=refs,remotes,status,stash-patches-only
EOF
  )

  if [ "$DRY_RUN" -eq 1 ]; then
    say "would write ${ARCHIVE_ROOT}/meta/archive-name.txt"
    say "would write ${ARCHIVE_ROOT}/meta/manifest.tsv"
    say "would write ${ARCHIVE_ROOT}/meta/repo-manifest.tsv"
    say "would write ${ARCHIVE_ROOT}/meta/summary.txt"
    say "would write ${SNAPSHOT_DIR}/meta/archive-name.txt"
    say "would write ${SNAPSHOT_DIR}/meta/manifest.tsv"
    say "would write ${SNAPSHOT_DIR}/meta/repo-manifest.tsv"
    say "would write ${SNAPSHOT_DIR}/meta/restore-instructions.txt"
    say "would write ${SNAPSHOT_DIR}/meta/summary.txt"
    say "would refresh legacy manifest: ${MANIFEST_LEGACY}"
  else
    write_path "$(stage_path "meta/archive-name.txt")" "${archive_name}"$'\n'
    write_path "$(stage_path "meta/manifest.tsv")" "$MANIFEST_LINES"
    write_path "$(stage_path "meta/repo-manifest.tsv")" "$REPO_MANIFEST_LINES"
    write_path "$(stage_path "meta/summary.txt")" "$summary"

    write_snapshot_text "meta/archive-name.txt" "${archive_name}"$'\n'
    write_snapshot_text "meta/manifest.tsv" "$MANIFEST_LINES"
    write_snapshot_text "meta/repo-manifest.tsv" "$REPO_MANIFEST_LINES"
    write_snapshot_text "meta/restore-instructions.txt" "$restore_instructions"
    write_snapshot_text "meta/summary.txt" "$summary"

    mkdir -p -- "$(dirname "$MANIFEST_LEGACY")"
    printf '%s' "$REPO_MANIFEST_LINES" >"$MANIFEST_LEGACY"
  fi
}

create_archive() {
  local stage_archive_root

  validate_parent_dir_path "$ARCHIVE_PATH" "archive"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would create archive: ${ARCHIVE_PATH}"
    return 0
  fi

  validate_directory_path "$STAGE_ROOT" "stage root"
  stage_archive_root="${STAGE_ROOT}/${ARCHIVE_ROOT}"
  [ -d "$stage_archive_root" ] || die "stage archive root missing: ${stage_archive_root}"

  if ! tar -C "$STAGE_ROOT" -czf "$ARCHIVE_PATH" "$ARCHIVE_ROOT"; then
    die "failed to create archive: ${ARCHIVE_PATH}"
  fi
}

archive_root_from_tar() {
  local first root

  validate_nonempty_path "$ARCHIVE_PATH" "archive"
  [ -f "$ARCHIVE_PATH" ] || die "archive not found: ${ARCHIVE_PATH}"

  first=$(tar -tzf "$ARCHIVE_PATH" 2>/dev/null | sed -n '1p') || return 1
  first=${first#./}
  [ -n "$first" ] || return 1
  root=${first%%/*}
  case "$root" in
    ""|"."|".."|/*)
      return 1
      ;;
  esac
  printf '%s\n' "$root"
}

extract_archive_to() {
  local target_root="$1" archive_root

  validate_directory_path "$target_root" "extract target"
  archive_root=$(archive_root_from_tar) || die "could not determine archive root from ${ARCHIVE_PATH}"
  mkdir -p -- "$target_root"
  if ! tar -xzf "$ARCHIVE_PATH" -C "$target_root"; then
    die "failed to extract archive: ${ARCHIVE_PATH}"
  fi
  [ -e "${target_root}/${archive_root}" ] || die "archive extracted without expected root: ${archive_root}"
  printf '%s/%s\n' "$target_root" "$archive_root"
}

verify_required_path() {
  local path="$1" label="$2"

  if [ ! -e "$path" ]; then
    say "verify failed: missing ${label}: ${path}"
    return 1
  fi
  VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
}

verify_manifest_entries() {
  local extracted_root="$1" manifest="$1/meta/manifest.tsv" rel label

  verify_required_path "$extracted_root/RESTORE.txt" "restore instructions" || return 1
  verify_required_path "$extracted_root/meta/summary.txt" "summary" || return 1
  verify_required_path "$manifest" "manifest" || return 1

  while IFS=$'\t' read -r rel label; do
    [ -n "${rel:-}" ] || continue
    verify_required_path "${extracted_root}/${rel}" "${label}" || return 1
  done <"$manifest"

  say "verified manifest entries: ${manifest}"
}

run_archive_verification() {
  local keep_dir="${1:-0}" prune_after="${2:-0}" phase_label="${3:-Verify restore}"
  local verify_dir extracted_root

  need mktemp
  need tar
  validate_parent_dir_path "$VERIFY_ROOT" "verify root"
  mkdir -p -- "$VERIFY_ROOT"
  verify_dir=$(mktemp -d "${VERIFY_ROOT}/verify-${TIMESTAMP}.XXXXXX")
  VERIFIED_COUNT=0

  if ! tar -tzf "$ARCHIVE_PATH" >/dev/null; then
    say "verify failed: archive listing failed: ${ARCHIVE_PATH}"
    say "  temp_dir:  ${verify_dir}"
    return 1
  fi
  VERIFIED_COUNT=$((VERIFIED_COUNT + 1))

  if ! extracted_root=$(extract_archive_to "$verify_dir"); then
    say "verify failed: archive extraction failed: ${ARCHIVE_PATH}"
    say "  temp_dir:  ${verify_dir}"
    return 1
  fi

  if ! verify_manifest_entries "$extracted_root"; then
    say "  temp_dir:  ${verify_dir}"
    return 1
  fi

  say
  say "${phase_label} complete"
  say "  archive:    ${ARCHIVE_PATH}"
  say "  verified:   ${VERIFIED_COUNT}"

  if [ "$keep_dir" -eq 1 ]; then
    say "  temp_dir:   ${verify_dir}"
  else
    rm -rf -- "$verify_dir"
    say "  temp_dir:   ${verify_dir} (removed)"
  fi

  if [ "$prune_after" -eq 1 ]; then
    prune_old_snapshots
  fi
}

prune_old_snapshots() {
  local include_pending_snapshot="${1:-0}"
  local -a snapshots=()
  local snapshot archive pruned=0

  mapfile -t snapshots < <(
    {
      if [ -d "$BACKUP_ROOT" ]; then
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z'
      fi

      if [ "$include_pending_snapshot" -eq 1 ] && [ "$DRY_RUN" -eq 1 ] && [ -n "${SNAPSHOT_DIR:-}" ]; then
        case "$(basename -- "$SNAPSHOT_DIR")" in
          ????????T??????Z)
            printf '%s\n' "$SNAPSHOT_DIR"
            ;;
        esac
      fi
    } | sort -u
  )

  while [ "${#snapshots[@]}" -gt "$KEEP_COUNT" ]; do
    snapshot="${snapshots[0]}"
    archive=$(archive_path_for_snapshot "$snapshot" 2>/dev/null || printf '%s/%s\n' "$BACKUP_ROOT" "$(archive_basename_for_timestamp "$(basename "$snapshot")")")
    if [ "$DRY_RUN" -eq 1 ]; then
      say "would prune old snapshot: ${snapshot}"
      [ -e "$archive" ] && say "would prune old archive: ${archive}"
    else
      rm -rf -- "$snapshot"
      say "pruned old snapshot: ${snapshot}"
      if [ -e "$archive" ]; then
        rm -f -- "$archive"
        say "pruned old archive: ${archive}"
      fi
    fi
    pruned=$((pruned + 1))
    snapshots=("${snapshots[@]:1}")
  done

  if [ "$pruned" -eq 0 ]; then
    say "old snapshot prune: none"
  fi
}

run_backup() {
  need find
  need git
  if [ "$DRY_RUN" -eq 0 ]; then
    need mktemp
    need tar
  fi
  validate_safe_host_path "$BACKUP_ROOT" "backup root"
  validate_directory_path "$BACKUP_ROOT" "backup root"
  validate_optional_source_dir_path "$WRKFLO_CONFIG_DIR" "wrkflo config"
  validate_optional_source_dir_path "$USER_BIN_DIR" "user bin"
  validate_optional_source_dir_path "$SSH_DIR" "SSH keys"

  SNAPSHOT_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
  ARCHIVE_PATH="${BACKUP_ROOT}/$(archive_basename_for_timestamp "$TIMESTAMP")"
  ARCHIVE_ROOT=$(archive_root_from_path "$ARCHIVE_PATH")
  MANIFEST_LINES=""
  REPO_MANIFEST_LINES=""
  REPO_COUNT=0
  SAVED_COUNT=0
  SKIPPED_COUNT=0

  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf -- "$SNAPSHOT_DIR"
    rm -f -- "$ARCHIVE_PATH"
    mkdir -p -- "$BACKUP_ROOT" "$SNAPSHOT_DIR"
    STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dws-backup.${TIMESTAMP}.XXXXXX")
  else
    STAGE_ROOT=""
    say "would create snapshot dir: ${SNAPSHOT_DIR}"
  fi

  copy_stage_tree "$WRKFLO_CONFIG_DIR" "home/.config/wrkflo" "wrkflo config"
  copy_stage_tree "$USER_BIN_DIR" "home/bin" "user bin"
  copy_stage_tree "$SSH_DIR" "home/.ssh" "SSH keys"
  capture_tmux_layouts
  capture_crontab
  backup_git_metadata
  write_metadata
  create_archive
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would verify backup archive: ${ARCHIVE_PATH}"
  elif ! run_archive_verification 0 0 "Backup verification"; then
    die "backup verification failed: ${ARCHIVE_PATH}"
  fi
  set_latest_symlink
  prune_old_snapshots "$DRY_RUN"

  say
  say "Backup complete"
  say "  snapshot:  ${SNAPSHOT_DIR}"
  say "  archive:   ${ARCHIVE_PATH}"
  say "  repos:     ${REPO_COUNT}"
  say "  saved:     ${SAVED_COUNT}"
  say "  skipped:   ${SKIPPED_COUNT}"
  say "  restore:   extract the archive and read ${ARCHIVE_ROOT}/RESTORE.txt"
}

run_restore() {
  local target_root extracted_root

  resolve_backup_reference
  ARCHIVE_ROOT=$(archive_root_from_path "$ARCHIVE_PATH")
  if [ -n "$RESTORE_TARGET" ]; then
    target_root="$RESTORE_TARGET"
  elif [ "$DRY_RUN" -eq 1 ]; then
    target_root="${TMPDIR:-/tmp}/dws-restore.${TIMESTAMP}.<tempdir>"
  else
    need mktemp
    target_root=$(mktemp -d "${TMPDIR:-/tmp}/dws-restore.${TIMESTAMP}.XXXXXX")
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    say
    say "Restore dry-run"
    say "  archive:     ${ARCHIVE_PATH}"
    say "  target_root: ${target_root}"
    say "  extracted:   ${target_root}/${ARCHIVE_ROOT}"
    return 0
  fi

  extracted_root=$(extract_archive_to "$target_root")
  RESTORED_COUNT=1

  say
  say "Restore extraction complete"
  say "  archive:       ${ARCHIVE_PATH}"
  say "  extracted:     ${extracted_root}"
  say "  instructions:  ${extracted_root}/RESTORE.txt"
}

run_verify_restore() {
  local keep_dir

  resolve_backup_reference
  ARCHIVE_ROOT=$(archive_root_from_path "$ARCHIVE_PATH")
  keep_dir=0
  if [ "$KEEP_VERIFY_DIR" = "1" ]; then
    keep_dir=1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    say
    say "Verify restore dry-run"
    say "  archive:      ${ARCHIVE_PATH}"
    say "  verify_root:  ${VERIFY_ROOT}"
    say "  checks:       archive extraction plus manifest entries"
    if [ "$PRUNE_AFTER_VERIFY" -eq 1 ]; then
      say "  prune:        after successful verification"
      prune_old_snapshots
    fi
    return 0
  fi

  run_archive_verification "$keep_dir" "$PRUNE_AFTER_VERIFY" "Verify restore"
}

case "${1:-}" in
  backup|cron|restore|verify-restore)
    MODE="$1"
    shift
    ;;
  --restore)
    MODE="restore"
    shift
    ;;
  --verify-restore)
    MODE="verify-restore"
    shift
    ;;
  "") ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --root)
      shift
      BACKUP_ROOT="${1:-}"
      ;;
    --keep|--keep-count|--keep-days)
      shift
      KEEP_COUNT="${1:-}"
      ;;
    --verify-root)
      shift
      VERIFY_ROOT="${1:-}"
      ;;
    --target)
      shift
      RESTORE_TARGET="${1:-}"
      ;;
    --archive)
      shift
      ARCHIVE_PATH="${1:-}"
      ;;
    --snapshot|--snapshot-dir)
      shift
      SNAPSHOT_DIR="${1:-}"
      ;;
    --prune)
      PRUNE_AFTER_VERIFY=1
      ;;
    --verify-restore)
      MODE="verify-restore"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if { [ "$MODE" = "restore" ] || [ "$MODE" = "verify-restore" ]; } && [ -z "$SNAPSHOT_DIR" ] && [ -z "$ARCHIVE_PATH" ]; then
        SNAPSHOT_DIR="$1"
      else
        usage >&2
        exit 1
      fi
      ;;
  esac
  shift
done

is_int "$KEEP_COUNT" || die "--keep must be an integer"
[ "$KEEP_COUNT" -ge 1 ] || die "--keep must be at least 1"
validate_nonempty_path "$BACKUP_ROOT" "backup root"
validate_nonempty_path "$VERIFY_ROOT" "verify root"
validate_safe_host_path "$VERIFY_ROOT" "verify root"
validate_nonempty_path "$TIMESTAMP" "timestamp"
case "$KEEP_VERIFY_DIR" in
  0|1) ;;
  *) die "DWS_VERIFY_RESTORE_KEEP must be 0 or 1" ;;
esac
if [ "$PRUNE_AFTER_VERIFY" -eq 1 ] && [ "$MODE" != "verify-restore" ] && [ "$MODE" != "cron" ]; then
  die "--prune requires verify-restore or cron"
fi

case "$MODE" in
  backup)
    run_backup
    ;;
  cron)
    run_backup
    run_verify_restore
    ;;
  restore)
    run_restore
    ;;
  verify-restore)
    run_verify_restore
    ;;
esac
