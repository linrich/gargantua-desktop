#!/bin/zsh
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
if (( $# < 1 || $# > 2 )) || [[ $# == 2 && "$2" != "--ad-hoc" ]]; then
    print -u2 "用法：zsh Scripts/sign-app.sh /path/to/Gargantua.app [--ad-hoc]"
    exit 2
fi
APP_DIR="$1"
# Explicit local mode never reads personal signing configuration or Keychain.
if [[ "${2:-}" == "--ad-hoc" ]] || [[ ! -e "$PROJECT_DIR/Signing/LocalSigning.plist" && ! -L "$PROJECT_DIR/Signing/LocalSigning.plist" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"
    python3 "$PROJECT_DIR/Scripts/verify_signing.py" "$APP_DIR" --ad-hoc
    exit 0
fi
CONFIG="$PROJECT_DIR/Signing/LocalSigning.plist"
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
