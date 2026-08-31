#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root/apps/ios/EpistoriaCore"

EPISTORIA_RUN_SCALE_TESTS=1 swift test \
  --filter LifelongArchiveScaleTests/testFullLifelongArchiveScaleWhenEnabled
