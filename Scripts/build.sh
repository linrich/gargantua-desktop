#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

# Build in the project plus an isolated temporary signing directory.
# No installation, downloads, sudo or license acceptance.
if ! xcrun --find swiftc >/dev/null; then
    print -u2 "Xcode 尚未就绪。请本人打开 Xcode 完成首次启动和许可协议，再重试。"
    exit 1
fi
SIGNING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}gargantua-build.XXXXXX")"
APP_DIR="$SIGNING_DIR/Gargantua.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Shaders" "$PROJECT_DIR/build/ModuleCache"
xcrun swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$PROJECT_DIR/build/ModuleCache" \
    -framework AppKit -framework SwiftUI -framework Metal -framework MetalKit \
    -framework MetalPerformanceShaders -framework QuartzCore \
    -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
    Sources/Gargantua/*.swift \
    -o "$APP_DIR/Contents/MacOS/Gargantua"
cp -X Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp -X Sources/Gargantua/Shaders/*.metal "$APP_DIR/Contents/Resources/Shaders/"
cp -X LICENSE NOTICE "$APP_DIR/Contents/Resources/"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
zsh "$PROJECT_DIR/Scripts/sign-app.sh" "$APP_DIR"
# Some managed Documents folders reattach FinderInfo to .app bundles.
# Sign before export and keep the ZIP free of unsupported metadata.
/usr/bin/ditto --norsrc "$APP_DIR" "$PROJECT_DIR/build/Gargantua.app"
print "构建完成：$PROJECT_DIR/build/Gargantua.app"
print "签名校验通过的构建副本：$APP_DIR"
print "可在 Finder 中双击 App；不会自动安装或启动。"
