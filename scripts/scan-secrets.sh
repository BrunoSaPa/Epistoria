#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if ! command -v git >/dev/null 2>&1; then
  printf 'git is required for the repository secret scan.\n' >&2
  exit 1
fi

# These patterns intentionally target high-confidence credential formats. Matching content is
# never printed, because emitting a discovered secret into CI logs would compound the leak.
credential_pattern='(sk-(proj-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----)'
found=0

while IFS= read -r -d '' file; do
  [[ -f "$file" ]] || continue
  if ! LC_ALL=C grep -Iq . "$file"; then
    continue
  fi
  if matches="$(LC_ALL=C grep -nE "$credential_pattern" "$file" | cut -d: -f1)"; then
    lines="$(printf '%s\n' "$matches" | paste -sd, -)"
    printf 'Potential credential format found in %s at line(s) %s.\n' "$file" "$lines" >&2
    found=1
  fi
done < <(git ls-files --cached --others --exclude-standard -z)

while IFS= read -r -d '' tracked; do
  basename="${tracked##*/}"
  case "$basename" in
    .env.example|.env.production.example) ;;
    .env|.env.*)
      printf 'Private environment file is tracked: %s\n' "$tracked" >&2
      found=1
      ;;
  esac
done < <(git ls-files -z)

if (( found != 0 )); then
  printf 'FAIL: repository secret scan found material requiring review.\n' >&2
  exit 1
fi

printf 'PASS: no high-confidence credential formats or private environment files found.\n'
