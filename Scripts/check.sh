#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
zsh Scripts/build.sh
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --instance-test "$PROJECT_DIR/build/verification"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --self-test "$PROJECT_DIR/build/verification"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --desktop-test "$PROJECT_DIR/build/verification"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --refresh-test "$PROJECT_DIR/build/verification"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --performance-test "$PROJECT_DIR/build/verification"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --psf-test "$PROJECT_DIR/build/verification/psf-float32"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --sampling-test "$PROJECT_DIR/build/verification/sampling"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --event-test "$PROJECT_DIR/build/verification/events"
"$PROJECT_DIR/build/Gargantua.app/Contents/MacOS/Gargantua" --resource-test checks "$PROJECT_DIR/build/verification/resources"
python3 Tests/verify_kerr_reference.py
python3 Tests/verify_bundle_reference.py
zsh Scripts/package.sh
