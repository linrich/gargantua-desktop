#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
OUTPUT="$PROJECT_DIR/build"
LOCAL_OUTPUT=false
AD_HOC=false
while (( $# )); do
    case "$1" in
        --output) (( $# >= 2 )) || exit 2; OUTPUT="${2:A}"; LOCAL_OUTPUT=true; shift 2 ;;
        --ad-hoc) AD_HOC=true; shift ;;
        *) print -u2 "用法：zsh Scripts/build.sh [--output 新目录 --ad-hoc]"; exit 2 ;;
    esac
done
if $AD_HOC && ! $LOCAL_OUTPUT; then
    print -u2 "本地 ad hoc 构建必须指定新的 --output 目录。"; exit 2
fi
if $LOCAL_OUTPUT; then
    if [[ -e "$OUTPUT" ]]; then
        print -u2 "输出目录已存在，拒绝覆盖：$OUTPUT"; exit 2
    fi
    mkdir -p "$OUTPUT"
fi
SIGNING_ARGS=()
if $AD_HOC; then SIGNING_ARGS=(--ad-hoc); fi

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
    -file-prefix-map "$PROJECT_DIR=." \
    -framework AppKit -framework SwiftUI -framework Metal -framework MetalKit \
    -framework MetalPerformanceShaders -framework QuartzCore \
    -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
    Sources/Gargantua/*.swift \
    -o "$APP_DIR/Contents/MacOS/Gargantua"
cp -X Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp -X Sources/Gargantua/Shaders/*.metal "$APP_DIR/Contents/Resources/Shaders/"
cp -X LICENSE NOTICE "$APP_DIR/Contents/Resources/"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
zsh "$PROJECT_DIR/Scripts/sign-app.sh" "$APP_DIR" "${SIGNING_ARGS[@]}"
# Some managed Documents folders reattach FinderInfo to .app bundles.
# Sign before export and keep the ZIP free of unsupported metadata.
/usr/bin/ditto --norsrc "$APP_DIR" "$OUTPUT/Gargantua.app"
if $LOCAL_OUTPUT; then print -r -- "$APP_DIR" > "$OUTPUT/signed-app-path.txt"; fi
print "构建完成：$OUTPUT/Gargantua.app"
print "签名校验通过的构建副本：$APP_DIR"
print "可在 Finder 中双击 App；不会自动安装或启动。"
