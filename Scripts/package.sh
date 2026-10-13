#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/build/Gargantua.app"
ARCHIVE="$PROJECT_DIR/build/Gargantua-macOS.zip"

# ZIP contains only generated App files. Exclude Finder/resource-fork attributes,
# which some file providers reattach to .app directories after signing.
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE"
VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}gargantua-package.XXXXXX")"
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
python3 "$PROJECT_DIR/Scripts/verify_signing.py" "$VERIFY_DIR/Gargantua.app"
# Use a relative file name so recipients can verify from their download folder.
(cd "$PROJECT_DIR/build" && /usr/bin/shasum -a 256 Gargantua-macOS.zip > Gargantua-macOS.zip.sha256)
print "ZIP 解包后的签名验证通过：$ARCHIVE"
print "临时校验副本：$VERIFY_DIR/Gargantua.app"
