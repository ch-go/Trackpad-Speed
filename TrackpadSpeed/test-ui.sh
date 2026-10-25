#!/bin/zsh
set -eu
cd "${0:A:h}"
TS_UI_TEST_BIN="$(mktemp -t trackpadspeed-ui-tests)"
trap 'rm -f "$TS_UI_TEST_BIN"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -DTS_TESTING=1 -I Sources -framework Cocoa -framework ServiceManagement -framework IOKit Sources/Curve.m Sources/PresetStore.m Sources/CurvePreview.m Sources/Backend.m Sources/Log.m Sources/PointerTrace.m Tests/UITests.m -o "$TS_UI_TEST_BIN"
"$TS_UI_TEST_BIN"
