// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Describes every input to the stationary desktop pass. It deliberately holds
// no texture or capture frame: remembering a presentation must not pin an
// IOSurface from ScreenCaptureKit's three-frame queue.
struct DesktopRefreshKey: Equatable {
    var sequence: UInt64?
    var outputSize: SIMD2<Int>
    var rect: SIMD4<Float>
    var viewport: SIMD4<Float>
    var spin: Float
    var inclination: Float
    var strength: Float
    var enabled: Bool
}

struct DesktopRefreshState {
    private var submitted: DesktopRefreshKey?

    func needsDraw(_ key: DesktopRefreshKey) -> Bool { submitted != key }
    // Call only after submission, never when a drawable or command is absent.
    mutating func didSubmit(_ key: DesktopRefreshKey) { submitted = key }
    mutating func invalidate() { submitted = nil }
}
