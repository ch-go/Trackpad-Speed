#!/bin/zsh
set -eu
cd "${0:A:h}"
TS_STORAGE_BIN="$(mktemp -t trackpadspeed-storage-tests)"
trap 'rm -f "$TS_STORAGE_BIN"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -DTS_TESTING=1 -I Sources -framework Foundation Sources/Curve.m Sources/Log.m Sources/PresetStore.m Tests/StorageTests.m -o "$TS_STORAGE_BIN"
"$TS_STORAGE_BIN"
