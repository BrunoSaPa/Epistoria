#!/usr/bin/env bash
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${EPISTORIA_COMPOSE_FILE:-$project_root/infra/docker-compose.yml}"
backup_root="${EPISTORIA_BACKUP_ROOT:-$project_root/backups}"
object_source="${EPISTORIA_OBJECT_SOURCE:-${EPISTORIA_RCLONE_REMOTE:-}}"
object_mirror="${EPISTORIA_OBJECT_MIRROR:-${EPISTORIA_OBJECT_MIRROR_DIR:-}}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$backup_root/$timestamp"
compose=(docker compose)
if [[ -n "${EPISTORIA_COMPOSE_ENV_FILE:-}" ]]; then
  compose+=(--env-file "$EPISTORIA_COMPOSE_ENV_FILE")
fi
compose+=(-f "$compose_file")

mkdir -p "$backup_root"
if [[ -e "$destination" ]]; then
  printf 'Backup destination already exists: %s\n' "$destination" >&2
  exit 1
fi

work_directory="$(mktemp -d "$backup_root/.in-progress-${timestamp}.XXXXXX")"
cleanup() {
  if [[ -d "$work_directory" ]]; then
    rm -r -- "$work_directory"
  fi
}
trap cleanup EXIT

"${compose[@]}" exec -T postgres sh -ec \
  'pg_dump --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --format=custom --no-owner --no-acl' \
  > "$work_directory/database.dump"

"${compose[@]}" exec -T postgres sh -ec \
  'psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-align --tuples-only --field-separator=, --command="SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM devices), (SELECT count(*) FROM entity_envelopes), (SELECT count(*) FROM change_log), (SELECT COALESCE(max(sequence), 0) FROM change_log), (SELECT count(*) FROM asset_objects), (SELECT count(*) FROM conflict_candidates WHERE resolved_at IS NULL);"' \
  > "$work_directory/database-summary.csv"

"${compose[@]}" exec -T postgres sh -ec \
  'psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-align --tuples-only --field-separator=, --command="SELECT id, object_key, byte_size, state FROM asset_objects ORDER BY id;"' \
  > "$work_directory/asset-inventory.csv"

printf 'created_at=%s\ncompose_file=%s\nformat=pg_dump_custom_v1\n' \
  "$timestamp" "$compose_file" > "$work_directory/backup-metadata.txt"

if [[ -n "$object_mirror" && -z "$object_source" ]]; then
  printf 'An object mirror requires EPISTORIA_OBJECT_SOURCE (or legacy EPISTORIA_RCLONE_REMOTE).\n' >&2
  exit 1
fi

if [[ -n "$object_source" ]]; then
  if ! command -v rclone >/dev/null 2>&1; then
    printf 'Object storage is configured but rclone is not installed.\n' >&2
    exit 1
  fi
  rclone lsf --recursive --files-only --format ps --separator '|' "$object_source" \
    | LC_ALL=C sort > "$work_directory/object-storage-inventory.txt"
  cut -d '|' -f 1 "$work_directory/object-storage-inventory.txt" \
    > "$work_directory/object-storage-paths.txt"
  if [[ -n "$object_mirror" ]]; then
    rclone copy --immutable --files-from-raw "$work_directory/object-storage-paths.txt" \
      "$object_source" "$object_mirror"
  fi
fi

(
  cd "$work_directory"
  manifest_files=(database.dump database-summary.csv asset-inventory.csv backup-metadata.txt)
  if [[ -f object-storage-inventory.txt ]]; then
    manifest_files+=(object-storage-inventory.txt object-storage-paths.txt)
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${manifest_files[@]}" > manifest.sha256
  else
    shasum -a 256 "${manifest_files[@]}" > manifest.sha256
  fi
)

mv "$work_directory" "$destination"
work_directory=""
printf '%s\n' "$timestamp" > "$backup_root/LATEST"
printf 'Backup completed: %s\n' "$destination"
