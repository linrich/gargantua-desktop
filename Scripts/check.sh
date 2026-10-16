#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
MODE="${1:-quick}"
OUTPUT="${2:-build/verification}"
OUTPUT="${OUTPUT:A}"
if [[ "$MODE" != quick && "$MODE" != full ]]; then
    print -u2 "用法：zsh Scripts/check.sh [quick|full] [新输出目录]"; exit 2
fi
if [[ -e "$OUTPUT" ]]; then
    print -u2 "检查输出已存在，拒绝覆盖：$OUTPUT"; exit 2
fi
zsh Scripts/build.sh --output "$OUTPUT/build" --ad-hoc
APP_DIR="$(<"$OUTPUT/build/signed-app-path.txt")"
EXECUTABLE="$APP_DIR/Contents/MacOS/Gargantua"
# These checks use nonpersistent settings, generated images and test locks.
# Do not call --recycle-test: it explicitly performs real fixture recycling.
"$EXECUTABLE" --interface-test "$OUTPUT/interface"
"$EXECUTABLE" --desktop-test "$OUTPUT/desktop"
"$EXECUTABLE" --instance-test "$OUTPUT/instance"
if [[ "$MODE" == full ]]; then
    "$EXECUTABLE" --self-test "$OUTPUT/render"
    "$EXECUTABLE" --refresh-test "$OUTPUT/refresh"
    "$EXECUTABLE" --psf-test "$OUTPUT/psf"
    "$EXECUTABLE" --sampling-test "$OUTPUT/sampling"
    "$EXECUTABLE" --event-test "$OUTPUT/events"
    "$EXECUTABLE" --resource-test checks "$OUTPUT/resources"
    python3 Tests/verify_kerr_reference.py "$OUTPUT/render/kerr-geodesics.json"
    python3 Tests/verify_bundle_reference.py "$OUTPUT/render"
fi
zsh Scripts/package.sh --app "$APP_DIR" --output "$OUTPUT/Gargantua-check.zip" --ad-hoc
