#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required_version="2.46.0"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' \
    "XcodeGen ${required_version} is required to regenerate apps/ios/Epistoria.xcodeproj." \
    "Install it with Homebrew: brew install xcodegen"
  exit 1
fi

installed_version="$(xcodegen --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
if [[ "$installed_version" != "$required_version" && "${EPISTORIA_ALLOW_XCODEGEN_VERSION_MISMATCH:-0}" != "1" ]]; then
  printf 'Expected XcodeGen %s, found %s. Set EPISTORIA_ALLOW_XCODEGEN_VERSION_MISMATCH=1 to override.\n' \
    "$required_version" "${installed_version:-unknown}" >&2
  exit 1
fi

cd "$project_root/apps/ios"
xcodegen generate --spec project.yml
printf 'Generated %s\n' "$project_root/apps/ios/Epistoria.xcodeproj"

