// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

// Metadata only; used before creating a capture stream and by generated tests.
struct CaptureWindow {
    let id: CGWindowID
    let processID: pid_t?
    let bundleID: String?
    let title: String?
}

enum DesktopCapturePolicy {
    static let overlayTitle = "Gargantua"
    static let backgroundTitle = "Gargantua · Desktop Lens"

    static func excludedWindowIDs(in windows: [CaptureWindow], overlayIDs: Set<CGWindowID>,
                                  currentPID: pid_t) throws -> Set<CGWindowID> {
        // Resolve the actual NSPanel ID, not a title or the whole application.
        // Fail closed if ScreenCaptureKit cannot identify our overlay safely.
        guard !overlayIDs.isEmpty,!overlayIDs.contains(0),
              overlayIDs.allSatisfy({id in windows.contains(where: {$0.id == id && $0.processID == currentPID})}) else {
            throw RenderError.unavailable("未能识别黑洞悬浮窗口，已停止采集以避免画面反馈。")
        }
        return Set(windows.filter { window in
            if window.processID == currentPID { return overlayIDs.contains(window.id) }
            // Legacy duplicate instances use this title for their overlay too.
            // Their controls and unrelated applications remain in the scene.
            return window.bundleID == AppInstance.bundleIdentifier && [overlayTitle,backgroundTitle].contains(window.title ?? "")
        }.map(\.id))
    }
}
