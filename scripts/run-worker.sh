#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
environment_file="${EPISTORIA_WORKER_ENV_FILE:-$project_root/services/worker/.env}"

if [[ "${1:-}" == "--env-file" ]]; then
  if [[ $# -lt 3 ]]; then
    printf 'Usage: %s [--env-file path] <doctor|once|run|key-import|key-export>\n' "$0" >&2
    exit 2
  fi
  environment_file="$2"
  shift 2
fi

if [[ $# -lt 1 ]]; then
  printf 'Usage: %s [--env-file path] <doctor|once|run|key-import|key-export>\n' "$0" >&2
  exit 2
fi

if [[ ! -f "$environment_file" || -L "$environment_file" ]]; then
  printf 'Worker environment must be a regular, non-symlink file: %s\n' "$environment_file" >&2
  exit 1
fi

file_owner="$(stat -f '%u' "$environment_file" 2>/dev/null || stat -c '%u' "$environment_file")"
file_mode="$(stat -f '%OLp' "$environment_file" 2>/dev/null || stat -c '%a' "$environment_file")"
if [[ "$file_owner" != "$(id -u)" ]]; then
  printf 'Worker environment must be owned by the current user.\n' >&2
  exit 1
fi
if (( (8#$file_mode & 077) != 0 )); then
  printf 'Worker environment permissions are too broad; run chmod 600 %s\n' "$environment_file" >&2
  exit 1
fi

worker="$project_root/services/worker/.venv/bin/epistoria-worker"
if [[ ! -x "$worker" ]]; then
  printf 'Worker is not installed. Run make worker-install first.\n' >&2
  exit 1
fi

set -a
# The file is user-owned and mode 0600/0400. It must contain only shell-compatible KEY=value
# assignments and must never contain recovery words.
source "$environment_file"
set +a

exec "$worker" "$@"
