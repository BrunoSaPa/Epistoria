#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${EPISTORIA_COMPOSE_FILE:-$project_root/infra/docker-compose.yml}"
storage_root="${EPISTORIA_CANARY_STORAGE_ROOT:-$project_root/infra/data}"
synthetic_canary='EPISTORIA_SYNTHETIC_PLAINTEXT_CANARY_7E8D1D73'
found=0
compose=(docker compose)
if [[ -n "${EPISTORIA_COMPOSE_ENV_FILE:-}" ]]; then
  compose+=(--env-file "$EPISTORIA_COMPOSE_ENV_FILE")
fi
compose+=(-f "$compose_file")

scan_path() {
  local target="$1"
  if [[ -e "$target" ]] && rg --text --files-with-matches --fixed-strings \
    "$synthetic_canary" "$target" >/dev/null 2>&1; then
    printf 'FAIL: synthetic plaintext canary found under %s\n' "$target" >&2
    found=1
  fi
}

scan_path "$storage_root"

if [[ "${EPISTORIA_CANARY_SCAN_DOCKER_LOGS:-1}" == "1" ]] && command -v docker >/dev/null 2>&1; then
  if "${compose[@]}" ps --status running --quiet 2>/dev/null | grep -q .; then
    if "${compose[@]}" logs --no-color 2>/dev/null | \
      rg --fixed-strings "$synthetic_canary" >/dev/null; then
      printf 'FAIL: synthetic plaintext canary found in container logs\n' >&2
      found=1
    fi
  fi
fi

if [[ "$found" != "0" ]]; then
  exit 1
fi

printf 'PASS: no synthetic plaintext canary found in server storage or available logs.\n'
