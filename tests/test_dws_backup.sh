#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "${BASE_DIR}/.." && pwd)
SCRIPT="${REPO_ROOT}/bin/dws-backup.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

assert_file_contains() {
  local path="$1" needle="$2" text
  [ -f "$path" ] || fail "expected file at ${path}"
  text=$(cat "$path")
  assert_contains "$text" "$needle"
}

assert_tar_contains() {
  local archive="$1" path="$2"
  tar -tzf "$archive" | grep -Fx -- "$path" >/dev/null || fail "expected archive ${archive} to contain ${path}"
}

assert_tar_text_contains() {
  local archive="$1" path="$2" needle="$3" text
  text=$(tar -xOf "$archive" "$path" 2>/dev/null) || fail "expected ${path} inside ${archive}"
  assert_contains "$text" "$needle"
}

cleanup_fixture() {
  if [ -n "${ORIG_PATH:-}" ]; then
    export PATH="${ORIG_PATH}"
  fi

  if [ -n "${FIXTURE_ROOT:-}" ] && [ -d "${FIXTURE_ROOT}" ]; then
    rm -rf -- "${FIXTURE_ROOT}"
  fi
}

make_fixture() {
  FIXTURE_ROOT=$(mktemp -d "/tmp/dws-backup-test.XXXXXX")
  ORIG_PATH="${PATH}"

  export HOME="${FIXTURE_ROOT}/home"
  export TMPDIR="${FIXTURE_ROOT}/tmp"
  export DWS_BACKUP_ROOT="${FIXTURE_ROOT}/backups"
  export DWS_BACKUP_TIMESTAMP="20260423T000000Z"
  export DWS_BACKUP_KEEP_COUNT=5
  export DWS_PROJECTS_ROOT="${HOME}/projects"
  export DWS_WRKFLO_CONFIG_DIR="${HOME}/.config/wrkflo"
  export DWS_USER_BIN_DIR="${HOME}/bin"
  export DWS_SSH_DIR="${HOME}/.ssh"
  export DWS_VERIFY_RESTORE_ROOT="${FIXTURE_ROOT}/verify-root"

  FAKE_BIN="${FIXTURE_ROOT}/fake-bin"
  CRONTAB_FILE="${FIXTURE_ROOT}/crontab.txt"
  export PATH="${FAKE_BIN}:${PATH}"

  mkdir -p \
    "${TMPDIR}" \
    "${DWS_BACKUP_ROOT}" \
    "${DWS_PROJECTS_ROOT}" \
    "${DWS_WRKFLO_CONFIG_DIR}" \
    "${DWS_USER_BIN_DIR}" \
    "${DWS_SSH_DIR}" \
    "${DWS_VERIFY_RESTORE_ROOT}" \
    "${FAKE_BIN}"

  printf 'default_profile = "wrk"\n' >"${DWS_WRKFLO_CONFIG_DIR}/settings.toml"
  printf '#!/usr/bin/env bash\necho helper\n' >"${DWS_USER_BIN_DIR}/dev-helper"
  chmod +x "${DWS_USER_BIN_DIR}/dev-helper"
  printf 'PRIVATE KEY\n' >"${DWS_SSH_DIR}/id_ed25519"
  printf 'PUBLIC KEY\n' >"${DWS_SSH_DIR}/id_ed25519.pub"
  chmod 700 "${DWS_SSH_DIR}"
  chmod 600 "${DWS_SSH_DIR}/id_ed25519"
  printf '0 * * * * echo backup\n' >"${CRONTAB_FILE}"

  cat >"${FAKE_BIN}/crontab" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\${1:-}" = "-l" ]; then
  cat "${CRONTAB_FILE}"
  exit 0
fi

exit 1
EOF
  chmod +x "${FAKE_BIN}/crontab"

  cat >"${FAKE_BIN}/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
  list-sessions)
    printf 'dev\t1\t0\t2026-04-23 00:00:00\n'
    ;;
  list-windows)
    printf 'dev\t0\teditor\tb25f,120x30,0,0{60x30,0,0,0,59x30,61,0,1}\t1\t*\n'
    ;;
  list-panes)
    printf 'dev\t0\t0\t%s\tvim\t60x30\n' "${DWS_PROJECTS_ROOT}/app"
    printf 'dev\t0\t1\t%s\tbash\t59x30\n' "${DWS_PROJECTS_ROOT}/app"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${FAKE_BIN}/tmux"

  mkdir -p "${DWS_PROJECTS_ROOT}/app"
  git -C "${DWS_PROJECTS_ROOT}/app" init -q
  git -C "${DWS_PROJECTS_ROOT}/app" config user.name 'Test User'
  git -C "${DWS_PROJECTS_ROOT}/app" config user.email 'test@example.com'
  printf 'base\n' >"${DWS_PROJECTS_ROOT}/app/tracked.txt"
  git -C "${DWS_PROJECTS_ROOT}/app" add tracked.txt
  git -C "${DWS_PROJECTS_ROOT}/app" commit -q -m 'initial commit'
  printf 'stashed change\n' >>"${DWS_PROJECTS_ROOT}/app/tracked.txt"
  printf 'scratch\n' >"${DWS_PROJECTS_ROOT}/app/untracked.txt"
  git -C "${DWS_PROJECTS_ROOT}/app" stash push -u -m 'backup stash' >/dev/null
}

test_backup_creates_tarball_with_expected_contents() {
  local output snapshot archive archive_root latest_target

  make_fixture
  trap cleanup_fixture EXIT

  output=$("${SCRIPT}" backup 2>&1)
  snapshot="${DWS_BACKUP_ROOT}/${DWS_BACKUP_TIMESTAMP}"
  archive="${DWS_BACKUP_ROOT}/dws-backup-${DWS_BACKUP_TIMESTAMP}.tar.gz"
  archive_root="dws-backup-${DWS_BACKUP_TIMESTAMP}"

  [ -d "${snapshot}" ] || fail "expected snapshot dir at ${snapshot}"
  [ -f "${archive}" ] || fail "expected archive at ${archive}"
  [ -L "${DWS_BACKUP_ROOT}/latest" ] || fail "expected latest symlink"
  latest_target=$(readlink -f -- "${DWS_BACKUP_ROOT}/latest")
  [ "${latest_target}" = "${snapshot}" ] || fail "expected latest symlink to point to ${snapshot}"

  assert_contains "${output}" "Backup complete"
  assert_contains "${output}" "Backup verification complete"
  assert_contains "${output}" "archive:   ${archive}"
  assert_contains "${output}" "restore:   extract the archive and read ${archive_root}/RESTORE.txt"
  assert_file_contains "${snapshot}/meta/archive-name.txt" "dws-backup-${DWS_BACKUP_TIMESTAMP}.tar.gz"
  assert_file_contains "${snapshot}/meta/summary.txt" "repo_count=1"

  assert_tar_contains "${archive}" "${archive_root}/RESTORE.txt"
  assert_tar_contains "${archive}" "${archive_root}/home/.config/wrkflo/settings.toml"
  assert_tar_contains "${archive}" "${archive_root}/home/bin/dev-helper"
  assert_tar_contains "${archive}" "${archive_root}/home/.ssh/id_ed25519"
  assert_tar_contains "${archive}" "${archive_root}/system/crontab.txt"
  assert_tar_contains "${archive}" "${archive_root}/tmux/layouts.tsv"
  assert_tar_contains "${archive}" "${archive_root}/tmux/panes.tsv"
  assert_tar_contains "${archive}" "${archive_root}/projects-git/app/refs.tsv"
  assert_tar_contains "${archive}" "${archive_root}/projects-git/app/stashes.txt"
  assert_tar_contains "${archive}" "${archive_root}/projects-git/app/stash-patches/stash-00.patch"
  assert_tar_text_contains "${archive}" "${archive_root}/RESTORE.txt" "This backup intentionally stores refs, remotes, status, and stash patches only."
  assert_tar_text_contains "${archive}" "${archive_root}/projects-git/app/stashes.txt" "backup stash"
  assert_tar_text_contains "${archive}" "${archive_root}/projects-git/app/stash-patches/stash-00.patch" "stashed change"

  cleanup_fixture
  trap - EXIT
}

test_backup_skips_missing_optional_dirs_gracefully() {
  local output archive archive_root

  make_fixture
  trap cleanup_fixture EXIT

  rm -rf -- "${DWS_WRKFLO_CONFIG_DIR}" "${DWS_USER_BIN_DIR}"
  archive="${DWS_BACKUP_ROOT}/dws-backup-${DWS_BACKUP_TIMESTAMP}.tar.gz"
  archive_root="dws-backup-${DWS_BACKUP_TIMESTAMP}"

  output=$("${SCRIPT}" backup 2>&1)

  assert_contains "${output}" "skip wrkflo config: ${DWS_WRKFLO_CONFIG_DIR} missing"
  assert_contains "${output}" "skip user bin: ${DWS_USER_BIN_DIR} missing"
  assert_contains "${output}" "Backup verification complete"
  assert_contains "${output}" "skipped:   2"
  [ -f "${archive}" ] || fail "expected archive at ${archive}"
  assert_tar_contains "${archive}" "${archive_root}/home/.ssh/id_ed25519"

  cleanup_fixture
  trap - EXIT
}

test_backup_exits_non_zero_when_backup_root_is_invalid() {
  local output invalid_root

  make_fixture
  trap cleanup_fixture EXIT

  invalid_root="${FIXTURE_ROOT}/invalid-root"
  printf 'not a directory\n' >"${invalid_root}"

  if output=$("${SCRIPT}" backup --root "${invalid_root}" 2>&1); then
    fail "expected backup with invalid root to fail"
  fi

  assert_contains "${output}" "backup root is not a directory: ${invalid_root}"

  cleanup_fixture
  trap - EXIT
}

test_backup_exits_non_zero_when_source_path_is_not_directory() {
  local output invalid_source

  make_fixture
  trap cleanup_fixture EXIT

  invalid_source="${FIXTURE_ROOT}/not-a-dir"
  printf 'not a directory\n' >"${invalid_source}"

  if output=$(DWS_WRKFLO_CONFIG_DIR="${invalid_source}" "${SCRIPT}" backup 2>&1); then
    fail "expected backup with non-directory source path to fail"
  fi

  assert_contains "${output}" "wrkflo config is not a directory: ${invalid_source}"

  cleanup_fixture
  trap - EXIT
}

test_backup_exits_non_zero_when_source_path_is_unsafe() {
  local output

  make_fixture
  trap cleanup_fixture EXIT

  if output=$(DWS_SSH_DIR='/' "${SCRIPT}" backup 2>&1); then
    fail "expected backup with unsafe source path to fail"
  fi

  assert_contains "${output}" "SSH keys path must not be /"

  cleanup_fixture
  trap - EXIT
}

test_backup_dry_run_reports_actions_without_writing_files() {
  local output snapshot archive archive_root

  make_fixture
  trap cleanup_fixture EXIT

  snapshot="${DWS_BACKUP_ROOT}/${DWS_BACKUP_TIMESTAMP}"
  archive="${DWS_BACKUP_ROOT}/dws-backup-${DWS_BACKUP_TIMESTAMP}.tar.gz"
  archive_root="dws-backup-${DWS_BACKUP_TIMESTAMP}"

  output=$("${SCRIPT}" backup --dry-run 2>&1)

  assert_contains "${output}" "would create snapshot dir: ${snapshot}"
  assert_contains "${output}" "would back up wrkflo config: ${DWS_WRKFLO_CONFIG_DIR} -> ${archive_root}/home/.config/wrkflo"
  assert_contains "${output}" "would create archive: ${archive}"
  assert_contains "${output}" "would verify backup archive: ${archive}"
  assert_contains "${output}" "would refresh latest symlink: ${DWS_BACKUP_ROOT}/latest -> ${snapshot}"
  assert_contains "${output}" "old snapshot prune: none"
  assert_contains "${output}" "Backup complete"

  [ ! -e "${snapshot}" ] || fail "expected dry-run not to create snapshot dir"
  [ ! -e "${archive}" ] || fail "expected dry-run not to create archive"
  [ ! -L "${DWS_BACKUP_ROOT}/latest" ] || fail "expected dry-run not to create latest symlink"
  if find "${TMPDIR}" -maxdepth 1 -type d -name "dws-backup.${DWS_BACKUP_TIMESTAMP}.*" | grep -q .; then
    fail "expected dry-run not to create a backup staging dir"
  fi

  cleanup_fixture
  trap - EXIT
}

test_restore_and_verify_use_latest_snapshot_metadata() {
  local output restore_root extracted_root

  make_fixture
  trap cleanup_fixture EXIT

  "${SCRIPT}" backup >/dev/null
  restore_root="${FIXTURE_ROOT}/restore-root"
  extracted_root="${restore_root}/dws-backup-${DWS_BACKUP_TIMESTAMP}"

  output=$("${SCRIPT}" restore latest --target "${restore_root}" 2>&1)
  assert_contains "${output}" "Restore extraction complete"
  assert_contains "${output}" "instructions:  ${extracted_root}/RESTORE.txt"
  [ -f "${extracted_root}/RESTORE.txt" ] || fail "expected extracted restore instructions"
  [ -f "${extracted_root}/meta/manifest.tsv" ] || fail "expected extracted manifest"

  output=$("${SCRIPT}" verify-restore latest 2>&1)
  assert_contains "${output}" "Verify restore complete"
  assert_contains "${output}" "verified manifest entries:"
  assert_contains "${output}" "(removed)"

  cleanup_fixture
  trap - EXIT
}

test_restore_dry_run_reports_actions_without_creating_temp_dir() {
  local output archive archive_root restore_prefix

  make_fixture
  trap cleanup_fixture EXIT

  "${SCRIPT}" backup >/dev/null
  archive="${DWS_BACKUP_ROOT}/dws-backup-${DWS_BACKUP_TIMESTAMP}.tar.gz"
  archive_root="dws-backup-${DWS_BACKUP_TIMESTAMP}"
  restore_prefix="${TMPDIR}/dws-restore.${DWS_BACKUP_TIMESTAMP}."

  output=$("${SCRIPT}" restore latest --dry-run 2>&1)

  assert_contains "${output}" "Restore dry-run"
  assert_contains "${output}" "archive:     ${archive}"
  assert_contains "${output}" "target_root: ${restore_prefix}<tempdir>"
  assert_contains "${output}" "extracted:   ${restore_prefix}<tempdir>/${archive_root}"
  if find "${TMPDIR}" -maxdepth 1 -type d -name "dws-restore.${DWS_BACKUP_TIMESTAMP}.*" | grep -q .; then
    fail "expected dry-run not to create a restore temp dir"
  fi

  cleanup_fixture
  trap - EXIT
}

test_backup_dry_run_reports_pending_prune_without_deleting_old_snapshots() {
  local output oldest_archive oldest_snapshot timestamp

  make_fixture
  trap cleanup_fixture EXIT

  for timestamp in \
    20260418T000000Z \
    20260419T000000Z \
    20260420T000000Z \
    20260421T000000Z \
    20260422T000000Z
  do
    DWS_BACKUP_TIMESTAMP="${timestamp}" "${SCRIPT}" backup >/dev/null
  done

  DWS_BACKUP_TIMESTAMP=20260423T000000Z
  oldest_snapshot="${DWS_BACKUP_ROOT}/20260418T000000Z"
  oldest_archive="${DWS_BACKUP_ROOT}/dws-backup-20260418T000000Z.tar.gz"
  output=$("${SCRIPT}" backup --dry-run 2>&1)

  assert_contains "${output}" "would prune old snapshot: ${oldest_snapshot}"
  assert_contains "${output}" "would prune old archive: ${oldest_archive}"
  [ -d "${oldest_snapshot}" ] || fail "expected dry-run to keep oldest snapshot dir"
  [ -f "${oldest_archive}" ] || fail "expected dry-run to keep oldest archive"

  cleanup_fixture
  trap - EXIT
}

test_backup_prunes_to_last_five_snapshots() {
  local timestamp latest_target

  make_fixture
  trap cleanup_fixture EXIT

  for timestamp in \
    20260418T000000Z \
    20260419T000000Z \
    20260420T000000Z \
    20260421T000000Z \
    20260422T000000Z \
    20260423T000000Z
  do
    DWS_BACKUP_TIMESTAMP="${timestamp}" "${SCRIPT}" backup >/dev/null
  done

  [ ! -d "${DWS_BACKUP_ROOT}/20260418T000000Z" ] || fail "expected oldest snapshot dir to be pruned"
  [ ! -f "${DWS_BACKUP_ROOT}/dws-backup-20260418T000000Z.tar.gz" ] || fail "expected oldest archive to be pruned"
  [ -d "${DWS_BACKUP_ROOT}/20260423T000000Z" ] || fail "expected newest snapshot dir to remain"
  [ -f "${DWS_BACKUP_ROOT}/dws-backup-20260423T000000Z.tar.gz" ] || fail "expected newest archive to remain"

  latest_target=$(readlink -f -- "${DWS_BACKUP_ROOT}/latest")
  [ "${latest_target}" = "${DWS_BACKUP_ROOT}/20260423T000000Z" ] || fail "expected latest symlink to point to newest snapshot"

  cleanup_fixture
  trap - EXIT
}

test_backup_creates_tarball_with_expected_contents
test_backup_skips_missing_optional_dirs_gracefully
test_backup_exits_non_zero_when_backup_root_is_invalid
test_backup_exits_non_zero_when_source_path_is_not_directory
test_backup_exits_non_zero_when_source_path_is_unsafe
test_backup_dry_run_reports_actions_without_writing_files
test_restore_and_verify_use_latest_snapshot_metadata
test_restore_dry_run_reports_actions_without_creating_temp_dir
test_backup_dry_run_reports_pending_prune_without_deleting_old_snapshots
test_backup_prunes_to_last_five_snapshots
printf 'ok\n'
