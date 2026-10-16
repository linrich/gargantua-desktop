#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/build/Gargantua.app"
ARCHIVE="$PROJECT_DIR/build/Gargantua-macOS.zip"
EXPLICIT_OUTPUT=false
AD_HOC=false
while (( $# )); do
    case "$1" in
        --app) (( $# >= 2 )) || exit 2; APP_DIR="${2:A}"; shift 2 ;;
        --output) (( $# >= 2 )) || exit 2; ARCHIVE="${2:A}"; EXPLICIT_OUTPUT=true; shift 2 ;;
        --ad-hoc) AD_HOC=true; shift ;;
        *) print -u2 "用法：zsh Scripts/package.sh [--app App路径 --output 新ZIP路径 --ad-hoc]"; exit 2 ;;
    esac
done
if $AD_HOC && ! $EXPLICIT_OUTPUT; then
    print -u2 "本地 ad hoc 打包必须指定新的 --output ZIP。"; exit 2
fi
if $EXPLICIT_OUTPUT && [[ -e "$ARCHIVE" || -e "$ARCHIVE.sha256" || -e "$ARCHIVE.verification.json" || -e "$ARCHIVE.unpacked-app-path.txt" ]]; then
    print -u2 "输出已存在，拒绝覆盖：$ARCHIVE"; exit 2
fi
VERIFY_ARGS=()
if $AD_HOC; then VERIFY_ARGS=(--ad-hoc); fi
# Validate the input before writing an archive.
python3 "$PROJECT_DIR/Scripts/verify_signing.py" "$APP_DIR" "${VERIFY_ARGS[@]}"
mkdir -p "${ARCHIVE:h}"

# ZIP contains only generated App files. Exclude Finder/resource-fork attributes,
# which some file providers reattach to .app directories after signing.
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE"
VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}gargantua-package.XXXXXX")"
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
python3 "$PROJECT_DIR/Scripts/verify_signing.py" "$VERIFY_DIR/Gargantua.app" "${VERIFY_ARGS[@]}" --output "$ARCHIVE.verification.json"
print -r -- "$VERIFY_DIR/Gargantua.app" > "$ARCHIVE.unpacked-app-path.txt"
(cd "${ARCHIVE:h}" && /usr/bin/shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256")
print "ZIP 解包后的签名验证通过：$ARCHIVE"
print "临时校验副本：$VERIFY_DIR/Gargantua.app"
