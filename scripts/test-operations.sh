#!/usr/bin/env bash
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/epistoria-operations-test.XXXXXX")"
trap 'rm -r -- "$temporary_root"' EXIT

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$project_root/scripts" -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)

if EPISTORIA_BACKUP_ROOT=/ "$project_root/scripts/prune-backups.sh" --apply \
  > "$temporary_root/broad-root.log" 2>&1
then
  printf 'Pruner unexpectedly accepted the filesystem root.\n' >&2
  exit 1
fi
if "$project_root/scripts/scheduled-backup.sh" > "$temporary_root/scheduler.log" 2>&1; then
  printf 'Scheduled backup unexpectedly accepted missing mirror configuration.\n' >&2
  exit 1
fi

unsafe_worker_env="$temporary_root/worker.env"
printf 'EPISTORIA_ACCOUNT_ID=00000000-0000-0000-0000-000000000000\n' > "$unsafe_worker_env"
chmod 644 "$unsafe_worker_env"
if "$project_root/scripts/run-worker.sh" --env-file "$unsafe_worker_env" doctor \
  > "$temporary_root/unsafe-worker.log" 2>&1
then
  printf 'Worker wrapper unexpectedly accepted broad environment permissions.\n' >&2
  exit 1
fi

backup_root="$temporary_root/backups"
mkdir -p "$backup_root"
for identifier in \
  20260310T021500Z \
  20260309T021500Z \
  20260308T021500Z \
  20260201T021500Z \
  20260101T021500Z
do
  mkdir -p "$backup_root/$identifier"
  printf 'created_at=%s\n' "$identifier" > "$backup_root/$identifier/backup-metadata.txt"
  : > "$backup_root/$identifier/database.dump"
  : > "$backup_root/$identifier/database-summary.csv"
  : > "$backup_root/$identifier/asset-inventory.csv"
  (
    cd "$backup_root/$identifier"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum database.dump database-summary.csv asset-inventory.csv backup-metadata.txt \
        > manifest.sha256
    else
      shasum -a 256 database.dump database-summary.csv asset-inventory.csv backup-metadata.txt \
        > manifest.sha256
    fi
  )
done
mkdir -p "$backup_root/20251201T021500Z"
printf 'created_at=20251201T021500Z\n' \
  > "$backup_root/20251201T021500Z/backup-metadata.txt"
printf '20260310T021500Z\n' > "$backup_root/LATEST"

retention_environment=(
  EPISTORIA_BACKUP_ROOT="$backup_root"
  EPISTORIA_RETAIN_DAILY=2
  EPISTORIA_RETAIN_WEEKLY=1
  EPISTORIA_RETAIN_MONTHLY=1
)
env "${retention_environment[@]}" "$project_root/scripts/prune-backups.sh" \
  > "$temporary_root/prune-dry-run.log"
test -d "$backup_root/20260101T021500Z"
grep -Fq 'Dry run only:' "$temporary_root/prune-dry-run.log"

env "${retention_environment[@]}" "$project_root/scripts/prune-backups.sh" --apply \
  > "$temporary_root/prune-apply.log"
test -d "$backup_root/20260310T021500Z"
test -d "$backup_root/20260309T021500Z"
test -d "$backup_root/20251201T021500Z"
test ! -e "$backup_root/20260308T021500Z"
test ! -e "$backup_root/20260201T021500Z"
test ! -e "$backup_root/20260101T021500Z"
grep -Fq 'Retention applied: 2 kept, 3 pruned, 1 skipped.' "$temporary_root/prune-apply.log"

mirror_backup="$temporary_root/mirror-backup"
mkdir -p "$mirror_backup" "$temporary_root/bin"
printf 'opaque-owner/opaque-object|123\n' > "$mirror_backup/object-storage-inventory.txt"
printf 'opaque-owner/opaque-object\n' > "$mirror_backup/object-storage-paths.txt"
(
  cd "$mirror_backup"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum object-storage-inventory.txt object-storage-paths.txt > manifest.sha256
  else
    shasum -a 256 object-storage-inventory.txt object-storage-paths.txt > manifest.sha256
  fi
)

fake_rclone="$temporary_root/bin/rclone"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'case "$1" in' \
  '  lsf) printf "opaque-owner/opaque-object|123\\n" ;;' \
  '  check) exit 0 ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$fake_rclone"
chmod 700 "$fake_rclone"
PATH="$temporary_root/bin:$PATH" \
EPISTORIA_OBJECT_SOURCE='source:encrypted-objects' \
EPISTORIA_OBJECT_MIRROR='mirror:encrypted-objects' \
  "$project_root/scripts/verify-object-mirror.sh" "$mirror_backup" \
  > "$temporary_root/mirror.log"
grep -Fq 'PASS: 1 opaque objects verified' "$temporary_root/mirror.log"
if PATH="$temporary_root/bin:$PATH" \
  EPISTORIA_OBJECT_SOURCE='same:encrypted-objects' \
  EPISTORIA_OBJECT_MIRROR='same:encrypted-objects' \
  "$project_root/scripts/verify-object-mirror.sh" "$mirror_backup" \
  > "$temporary_root/same-mirror.log" 2>&1
then
  printf 'Mirror verifier unexpectedly accepted identical source and mirror paths.\n' >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  plutil -lint "$project_root/infra/launchd/com.epistoria.worker.plist.template" >/dev/null
fi

"$project_root/scripts/scan-secrets.sh" >/dev/null
printf 'PASS: operational shell syntax, safe retention, mirror verification, plist, and secret scan.\n'
