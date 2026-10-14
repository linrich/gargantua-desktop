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
python3 Tests/verify_kerr_reference.py
python3 Tests/verify_bundle_reference.py
zsh Scripts/package.sh
