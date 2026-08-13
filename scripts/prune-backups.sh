#!/usr/bin/env bash
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_root="${EPISTORIA_BACKUP_ROOT:-$project_root/backups}"
retain_daily="${EPISTORIA_RETAIN_DAILY:-7}"
retain_weekly="${EPISTORIA_RETAIN_WEEKLY:-5}"
retain_monthly="${EPISTORIA_RETAIN_MONTHLY:-12}"
apply=0

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--apply" ) ]]; then
  printf 'Usage: %s [--apply]\n' "$0" >&2
  exit 2
fi
if [[ "${1:-}" == "--apply" ]]; then
  apply=1
fi

for value in "$retain_daily" "$retain_weekly" "$retain_monthly"; do
  if [[ ! "$value" =~ ^[1-9][0-9]*$ || "$value" -gt 365 ]]; then
    printf 'Retention counts must be integers from 1 through 365.\n' >&2
    exit 1
  fi
done
if [[ ! -d "$backup_root" || -L "$backup_root" ]]; then
  printf 'Backup root must be a regular directory: %s\n' "$backup_root" >&2
  exit 1
fi

resolved_root="$(cd "$backup_root" && pwd -P)"
resolved_project="$(cd "$project_root" && pwd -P)"
if [[ "$resolved_root" == "/" || "$resolved_root" == "$resolved_project" ]]; then
  printf 'Refusing to prune a broad directory: %s\n' "$resolved_root" >&2
  exit 1
fi
if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
  resolved_home="$(cd "$HOME" && pwd -P)"
  if [[ "$resolved_root" == "$resolved_home" ]]; then
    printf 'Refusing to prune the home directory.\n' >&2
    exit 1
  fi
fi

iso_week() {
  local day="$1"
  local calendar_date="${day:0:4}-${day:4:2}-${day:6:2}"
  if date -u -d "$calendar_date" '+%G-%V' >/dev/null 2>&1; then
    date -u -d "$calendar_date" '+%G-%V'
  elif date -j -u -f '%Y%m%d' "$day" '+%G-%V' >/dev/null 2>&1; then
    date -j -u -f '%Y%m%d' "$day" '+%G-%V'
  else
    return 1
  fi
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/epistoria-prune.XXXXXX")"
trap 'rm -r -- "$temporary_root"' EXIT
daily_keys="$temporary_root/daily"
weekly_keys="$temporary_root/weekly"
monthly_keys="$temporary_root/monthly"
candidate_list="$temporary_root/candidates"
: > "$daily_keys"
: > "$weekly_keys"
: > "$monthly_keys"
find "$resolved_root" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort -r \
  > "$candidate_list"

daily_used=0
weekly_used=0
monthly_used=0
kept=0
pruned=0
skipped=0

while IFS= read -r candidate; do
  name="${candidate##*/}"
  if [[ ! "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    continue
  fi
  if [[ -L "$candidate" \
    || ! -f "$candidate/database.dump" \
    || ! -f "$candidate/database-summary.csv" \
    || ! -f "$candidate/asset-inventory.csv" \
    || ! -f "$candidate/backup-metadata.txt" \
    || ! -f "$candidate/manifest.sha256" ]]
  then
    printf 'SKIP incomplete or unsafe backup directory: %s\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi
  recorded="$(sed -n 's/^created_at=//p' "$candidate/backup-metadata.txt" | head -n 1)"
  if [[ "$recorded" != "$name" ]]; then
    printf 'SKIP metadata mismatch: %s\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi
  if ! (
    cd "$candidate"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum --check --status manifest.sha256
    else
      shasum -a 256 --check manifest.sha256 >/dev/null
    fi
  ); then
    printf 'SKIP checksum verification failed: %s\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi

  day_key="${name:0:8}"
  month_key="${name:0:6}"
  if ! week_key="$(iso_week "$day_key")"; then
    printf 'SKIP invalid calendar date: %s\n' "$name"
    skipped=$((skipped + 1))
    continue
  fi
  keep=0
  if (( daily_used < retain_daily )) && ! grep -Fqx "$day_key" "$daily_keys"; then
    printf '%s\n' "$day_key" >> "$daily_keys"
    daily_used=$((daily_used + 1))
    keep=1
  fi
  if (( weekly_used < retain_weekly )) && ! grep -Fqx "$week_key" "$weekly_keys"; then
    printf '%s\n' "$week_key" >> "$weekly_keys"
    weekly_used=$((weekly_used + 1))
    keep=1
  fi
  if (( monthly_used < retain_monthly )) && ! grep -Fqx "$month_key" "$monthly_keys"; then
    printf '%s\n' "$month_key" >> "$monthly_keys"
    monthly_used=$((monthly_used + 1))
    keep=1
  fi

  if (( keep == 1 )); then
    printf 'KEEP %s\n' "$name"
    kept=$((kept + 1))
    continue
  fi

  if (( apply == 1 )); then
    resolved_candidate="$(cd "$candidate" && pwd -P)"
    if [[ "$resolved_candidate" != "$resolved_root/"* ]]; then
      printf 'Refusing candidate outside backup root: %s\n' "$name" >&2
      exit 1
    fi
    rm -r -- "$resolved_candidate"
    printf 'PRUNED %s\n' "$name"
  else
    printf 'WOULD_PRUNE %s\n' "$name"
  fi
  pruned=$((pruned + 1))
done < "$candidate_list"

if (( apply == 0 )); then
  printf 'Dry run only: %s kept, %s would be pruned, %s skipped. Rerun with --apply to delete.\n' \
    "$kept" "$pruned" "$skipped"
else
  printf 'Retention applied: %s kept, %s pruned, %s skipped.\n' "$kept" "$pruned" "$skipped"
fi
