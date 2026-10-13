// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum MotionTuning {
    static let referenceWidth = 760.0
    static let defaultSpeed = 0.05

    // Keep projected travel in AppKit points approximately constant as the
    // overlay is resized. Retina scale and render quality must not affect this.
    static func effectiveSpeed(_ speed: Double, width: Double) -> Double {
        max(0, speed) * referenceWidth / max(1, width)
    }

    // A logarithmic control gives the slow range useful travel while retaining
    // an exact stop and the previous 2x reference-speed maximum.
    static func sliderPosition(for speed: Double) -> Double {
        log1p(min(2,max(0,speed))/0.01)/log(201)
    }
    static func speed(at position: Double) -> Double {
        let value=0.01*expm1(min(1,max(0,position))*log(201))
        return (value*1000).rounded()/1000
    }
}

struct AnimationClock {
    private(set) var elapsed = 0.0
    private var lastWallTime: Double

    init(wallTime: Double) { lastWallTime=wallTime }
    mutating func synchronize(to now: Double) { lastWallTime=now }

    mutating func advance(to now: Double, rate: Double, paused: Bool) -> Double {
        let delta=max(0,min(now-lastWallTime,0.1))
        lastWallTime=now
        // Integrate increments; never multiply the whole elapsed time by a new
        // speed or size factor, which would teleport the material phase.
        if !paused {elapsed+=delta*max(0,rate)}
        return elapsed
    }
}
