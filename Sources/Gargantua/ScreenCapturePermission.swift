// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ScreenCaptureKit

// Injectable checks let validation exercise denial/retry without prompting or
// starting capture. Production still relies on the operating system's decision.
struct ScreenCapturePermission {
    var preflight: () -> Bool
    var request: () -> Bool
    static let system = Self(preflight: { CGPreflightScreenCaptureAccess() },
                             request: { CGRequestScreenCaptureAccess() })
    static let deniedMessage = "macOS 尚未允许当前版本录屏。如果设置中已开启，请重新添加当前 Gargantua，授权后退出并重新打开。"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    func ensureAccess() -> Bool { preflight() || request() }
    static func isDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }
}
