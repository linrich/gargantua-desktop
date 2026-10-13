// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum RenderDetail {
    // 3840 + the default PSF radius fits a 4096-wide FFT. Keep an explicit
    // budget rather than allocating unbounded geometry/FFT targets at full screen.
    static let maximumWidth = 3840
    static let maximumHeight = 2400
    static let brightnessRange = 0.35...5.0
    static let glowRange = 0.0...3.0

    static func materialWidth(for outputWidth: Int) -> Int {
        if outputWidth <= 768 {return 1024}
        if outputWidth <= 1280 {return 2048}
        if outputWidth <= 2560 {return 4096}
        return 8192
    }
}
