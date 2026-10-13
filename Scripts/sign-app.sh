#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
if (( $# != 1 )); then
    print -u2 "用法：zsh Scripts/sign-app.sh /path/to/Gargantua.app"
    exit 2
fi
APP_DIR="$1"
CONFIG="$PROJECT_DIR/Signing/LocalSigning.plist"
if [[ ! -e "$CONFIG" && ! -L "$CONFIG" ]]; then
    print "未配置固定证书：使用仅供本地开发的 ad hoc 签名。"
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"
    python3 "$PROJECT_DIR/Scripts/verify_signing.py" "$APP_DIR"
    exit 0
fi
CERTIFICATE_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$CONFIG")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$CONFIG")"
if [[ ! "$CERTIFICATE_SHA1" =~ '^[A-F0-9]{40}$' ]]; then
    print -u2 "签名证书指纹无效，已停止。"
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" != "$BUNDLE_ID" ]]; then
    print -u2 "App 标识与固定签名配置不一致，已停止。"
    exit 1
fi
# The private key remains in Keychain. No new certificates, exports, account
# login, timestamp request, or fallback to ad-hoc signing.
/usr/bin/codesign --force --sign "$CERTIFICATE_SHA1" --timestamp=none "$APP_DIR"
python3 "$PROJECT_DIR/Scripts/verify_signing.py" "$APP_DIR"
