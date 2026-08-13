#!/usr/bin/env bash
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
object_source="${EPISTORIA_OBJECT_SOURCE:-${EPISTORIA_RCLONE_REMOTE:-}}"
object_mirror="${EPISTORIA_OBJECT_MIRROR:-${EPISTORIA_OBJECT_MIRROR_DIR:-}}"

if [[ -z "$object_source" || -z "$object_mirror" ]]; then
  printf '%s\n' \
    'Scheduled backups require independently configured object source and mirror paths.' \
    'Set EPISTORIA_OBJECT_SOURCE and EPISTORIA_OBJECT_MIRROR in the protected scheduler environment.' >&2
  exit 1
fi

"$project_root/scripts/backup.sh"
"$project_root/scripts/verify-object-mirror.sh"
"$project_root/scripts/prune-backups.sh" --apply
printf 'Scheduled backup, independent mirror verification, and retention completed.\n'
