#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p "../Trackpad Speed.app/Contents/MacOS"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O2 -mmacosx-version-min=14.0 -framework Cocoa -framework IOKit Sources/Curve.m Sources/PresetStore.m Sources/CurvePreview.m Sources/Log.m Sources/PointerTrace.m Sources/Backend.m Sources/main.m -o "../Trackpad Speed.app/Contents/MacOS/TrackpadSpeed"
cp Info.plist "../Trackpad Speed.app/Contents/Info.plist"
codesign --force --sign - "../Trackpad Speed.app"
