#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker_root="$project_root/services/worker"
virtual_environment="$worker_root/.venv"
python_command="${EPISTORIA_WORKER_PYTHON:-python3}"

if ! command -v "$python_command" >/dev/null 2>&1; then
  printf 'Python executable not found: %s\n' "$python_command" >&2
  exit 1
fi

python_version="$($python_command -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ "$python_version" != "3.13" ]]; then
  printf 'Epistoria worker requires Python 3.13; %s reports %s.\n' \
    "$python_command" "$python_version" >&2
  exit 1
fi

if [[ -x "$virtual_environment/bin/python" ]]; then
  environment_version="$($virtual_environment/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$environment_version" != "3.13" ]]; then
    printf '%s\n' \
      "Existing worker environment uses Python $environment_version." \
      "Move $virtual_environment aside and rerun this installer; it will not delete an environment automatically." >&2
    exit 1
  fi
else
  "$python_command" -m venv "$virtual_environment"
fi

"$virtual_environment/bin/python" -m pip install \
  --disable-pip-version-check \
  --no-input \
  --quiet \
  --requirement "$worker_root/requirements.lock"

# Link this checkout directly instead of invoking a build backend. That keeps the developer
# install offline once locked dependencies exist and prevents build isolation from resolving an
# unrecorded dependency set. Packaging builds still use pyproject.toml explicitly.
site_packages="$($virtual_environment/bin/python -c 'import site; print(site.getsitepackages()[0])')"
printf '%s\n' "$worker_root/src" > "$site_packages/epistoria_worker_local.pth"
launcher="$virtual_environment/bin/epistoria-worker"
printf '%s\n' \
  '#!/bin/sh' \
  "exec \"$virtual_environment/bin/python\" -m epistoria_worker.cli \"\$@\"" \
  > "$launcher"
chmod 755 "$launcher"

"$virtual_environment/bin/python" -c \
  'import epistoria_worker; print("Epistoria worker dependency lock installed successfully.")'
