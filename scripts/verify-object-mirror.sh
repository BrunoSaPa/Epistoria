#!/usr/bin/env bash
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_root="${EPISTORIA_BACKUP_ROOT:-$project_root/backups}"
object_source="${EPISTORIA_OBJECT_SOURCE:-${EPISTORIA_RCLONE_REMOTE:-}}"
object_mirror="${EPISTORIA_OBJECT_MIRROR:-${EPISTORIA_OBJECT_MIRROR_DIR:-}}"
verification_mode="${EPISTORIA_MIRROR_VERIFY_MODE:-metadata}"
checkers="${EPISTORIA_MIRROR_CHECKERS:-4}"

if [[ -z "$object_source" || -z "$object_mirror" ]]; then
  printf '%s\n' \
    'Set EPISTORIA_OBJECT_SOURCE and EPISTORIA_OBJECT_MIRROR to independent rclone paths.' >&2
  exit 1
fi
if [[ "$object_source" == "$object_mirror" ]]; then
  printf 'Object source and mirror must be different rclone paths.\n' >&2
  exit 1
fi
if [[ "$verification_mode" != "metadata" && "$verification_mode" != "full" ]]; then
  printf 'EPISTORIA_MIRROR_VERIFY_MODE must be metadata or full.\n' >&2
  exit 1
fi
if [[ ! "$checkers" =~ ^[1-9][0-9]*$ || "$checkers" -gt 32 ]]; then
  printf 'EPISTORIA_MIRROR_CHECKERS must be an integer from 1 through 32.\n' >&2
  exit 1
fi
if ! command -v rclone >/dev/null 2>&1; then
  printf 'rclone is required for object mirror verification.\n' >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [backup-directory]\n' "$0" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  backup_directory="$(cd "$1" && pwd -P)"
elif [[ -f "$backup_root/LATEST" ]]; then
  latest="$(tr -d '[:space:]' < "$backup_root/LATEST")"
  if [[ ! "$latest" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    printf 'LATEST contains an invalid backup identifier.\n' >&2
    exit 1
  fi
  backup_directory="$(cd "$backup_root/$latest" && pwd -P)"
else
  printf 'No backup specified and %s/LATEST does not exist.\n' "$backup_root" >&2
  exit 1
fi

inventory="$backup_directory/object-storage-inventory.txt"
paths="$backup_directory/object-storage-paths.txt"
manifest="$backup_directory/manifest.sha256"
for required in "$inventory" "$paths" "$manifest"; do
  if [[ ! -f "$required" || -L "$required" ]]; then
    printf 'Backup lacks a regular mirror-verification file: %s\n' "${required##*/}" >&2
    exit 1
  fi
done

(
  cd "$backup_directory"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check --status manifest.sha256
  else
    shasum -a 256 --check manifest.sha256 >/dev/null
  fi
)

if ! awk '
  /^[^|]+\|[0-9]+$/ {
    path = $0
    sub(/\|[0-9]+$/, "", path)
    if (path !~ /^\// && path !~ /(^|\/)\.\.($|\/)/) next
  }
  { exit 1 }
' "$inventory"; then
  printf 'Object inventory contains an unsafe path or invalid size record.\n' >&2
  exit 1
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/epistoria-mirror-check.XXXXXX")"
trap 'rm -r -- "$temporary_root"' EXIT
source_inventory="$temporary_root/source.txt"
mirror_inventory="$temporary_root/mirror.txt"

if [[ -s "$paths" ]]; then
  rclone lsf --recursive --files-only --format ps --separator '|' \
    --files-from-raw "$paths" "$object_source" | LC_ALL=C sort > "$source_inventory"
  rclone lsf --recursive --files-only --format ps --separator '|' \
    --files-from-raw "$paths" "$object_mirror" | LC_ALL=C sort > "$mirror_inventory"
else
  : > "$source_inventory"
  : > "$mirror_inventory"
fi

if ! cmp -s "$inventory" "$source_inventory"; then
  printf 'Object source no longer matches the recorded backup inventory.\n' >&2
  exit 1
fi
if ! cmp -s "$inventory" "$mirror_inventory"; then
  printf 'Independent object mirror does not match the recorded backup inventory.\n' >&2
  exit 1
fi

if [[ -s "$paths" ]]; then
  check_arguments=(check "$object_source" "$object_mirror" --one-way --files-from-raw "$paths" --checkers "$checkers" --log-level ERROR)
  if [[ "$verification_mode" == "full" ]]; then
    check_arguments+=(--download)
  else
    check_arguments+=(--size-only)
  fi
  rclone "${check_arguments[@]}"
fi

object_count="$(wc -l < "$inventory" | tr -d '[:space:]')"
printf 'PASS: %s opaque objects verified against the independent mirror (%s mode).\n' \
  "$object_count" "$verification_mode"
