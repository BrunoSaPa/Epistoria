#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/epistoria-verify.XXXXXX")"
trap 'rm -r -- "$temporary_root"' EXIT

cd "$project_root"
scripts/scan-secrets.sh
node scripts/validate-contracts.mjs
node scripts/check-public-docs.mjs
npm run verify

worker_python="$project_root/services/worker/.venv/bin/python"
if [[ ! -x "$worker_python" ]]; then
  printf 'Worker environment is missing. Run make worker-install first.\n' >&2
  exit 1
fi
"$worker_python" -m ruff check services/worker
"$worker_python" -m mypy --config-file services/worker/pyproject.toml \
  services/worker/src
"$worker_python" -m pytest -q services/worker/tests

(
  cd apps/ios/EpistoriaCore
  SWIFTPM_MODULECACHE_OVERRIDE="$temporary_root/swift-module-cache" \
  CLANG_MODULE_CACHE_PATH="$temporary_root/clang-module-cache" \
    swift test --quiet
)

if [[ "$(uname -s)" == "Darwin" ]] && command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -quiet \
    -project apps/ios/Epistoria.xcodeproj \
    -scheme Epistoria \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$temporary_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets PrivacyInfo.xcprivacy' \
    build
fi

if [[ "${EPISTORIA_VERIFY_E2E:-0}" == "1" ]]; then
  scripts/test-api-e2e.sh
fi

scripts/plaintext-canary.sh
printf 'Epistoria verification passed.\n'
