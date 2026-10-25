#!/bin/zsh
set -eu
cd "${0:A:h}"
TS_TEST_BIN="$(mktemp -t trackpadspeed-tests)"
trap 'rm -f "$TS_TEST_BIN"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -DTS_TESTING=1 -I Sources -framework Foundation -framework IOKit Sources/Curve.m Sources/Backend.m Sources/Log.m Tests/Tests.m -o "$TS_TEST_BIN"
"$TS_TEST_BIN"
