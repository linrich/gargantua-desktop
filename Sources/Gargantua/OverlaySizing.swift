// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum OverlaySizing {
    static let minimum = 360.0
    static let aspect = 1.6

    // Largest uncropped 1.6:1 overlay inside the current screen's full frame.
    // This is a desktop panel fit, not a pixel-resolution limit.
    static func maximumWidth(in screen: CGSize) -> Double {
        max(1,floor(min(Double(screen.width),Double(screen.height)*aspect)))
    }
}
