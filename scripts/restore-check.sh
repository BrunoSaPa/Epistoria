#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${EPISTORIA_COMPOSE_FILE:-$project_root/infra/docker-compose.yml}"
backup_root="${EPISTORIA_BACKUP_ROOT:-$project_root/backups}"
compose=(docker compose)
if [[ -n "${EPISTORIA_COMPOSE_ENV_FILE:-}" ]]; then
  compose+=(--env-file "$EPISTORIA_COMPOSE_ENV_FILE")
fi
compose+=(-f "$compose_file")

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [backup-directory]\n' "$0" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  backup_directory="$(cd "$1" && pwd)"
elif [[ -f "$backup_root/LATEST" ]]; then
  latest="$(tr -d '[:space:]' < "$backup_root/LATEST")"
  backup_directory="$backup_root/$latest"
else
  printf 'No backup specified and %s/LATEST does not exist.\n' "$backup_root" >&2
  exit 1
fi

for required in database.dump database-summary.csv asset-inventory.csv backup-metadata.txt manifest.sha256; do
  if [[ ! -f "$backup_directory/$required" ]]; then
    printf 'Backup is incomplete; missing %s\n' "$required" >&2
    exit 1
  fi
done

(
  cd "$backup_directory"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check manifest.sha256
  else
    shasum -a 256 --check manifest.sha256
  fi
)

cleanup() {
  "${compose[@]}" --profile restore rm --stop --force restore-postgres \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

"${compose[@]}" --profile restore up -d --wait restore-postgres
"${compose[@]}" exec -T restore-postgres \
  pg_restore --exit-on-error --no-owner --no-privileges \
  --username=epistoria_restore --dbname=epistoria_restore \
  < "$backup_directory/database.dump"

restored_summary="$("${compose[@]}" exec -T restore-postgres \
  psql --username=epistoria_restore --dbname=epistoria_restore \
  --no-align --tuples-only --field-separator=, \
  --command='SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM devices), (SELECT count(*) FROM entity_envelopes), (SELECT count(*) FROM change_log), (SELECT COALESCE(max(sequence), 0) FROM change_log), (SELECT count(*) FROM asset_objects), (SELECT count(*) FROM conflict_candidates WHERE resolved_at IS NULL);')"
expected_summary="$(tr -d '\r\n' < "$backup_directory/database-summary.csv")"

if [[ "$restored_summary" != "$expected_summary" ]]; then
  printf 'Restore row-count verification failed.\nExpected: %s\nActual:   %s\n' \
    "$expected_summary" "$restored_summary" >&2
  exit 1
fi

failed_migrations="$("${compose[@]}" exec -T restore-postgres \
  psql --username=epistoria_restore --dbname=epistoria_restore --no-align --tuples-only \
  --command='SELECT count(*) FROM "_prisma_migrations" WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL;')"
if [[ "${failed_migrations//$'\r'/}" != "0" ]]; then
  printf 'Restore contains incomplete or rolled-back Prisma migrations.\n' >&2
  exit 1
fi

printf 'PASS: isolated restore matches the backup summary (%s).\n' "$restored_summary"
