// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// Ordinary URLs stay in memory for an explicitly enabled drag and its result.
// Test-session eligibility remains separate from ordinary file authorization.
struct DropToken {
    let kind: String
    let title: String
    var recycleTestURL: URL? = nil
    var recycleFileURL: URL? = nil
    static let samples = [DropToken(kind: "DOC", title: "示例文档"),
                          DropToken(kind: "IMG", title: "示例图片"),
                          DropToken(kind: "DIR", title: "示例文件夹")]
}

struct DiskHitMap {
    let width: Int
    let height: Int
    let surfaceCells: [Bool]
    let cells: [Bool]

    init(width: Int, height: Int, surfaceCells: [Bool]) {
        precondition(width > 0 && height > 0 && surfaceCells.count == width * height)
        self.width = width; self.height = height; self.surfaceCells = surfaceCells
        // The projected silhouette is continuous from its top to bottom
        // at each x. Its interior is a target even where no disk ray hits.
        // Filling column spans also closes the tiny side seams of the lower
        // inner gap, which an exterior flood fill incorrectly leaves open.
        // Keep each column's actual bounds; don't use an ellipse/bounding box.
        var filled = surfaceCells
        for x in 0..<width {
            guard let bottom = (0..<height).first(where: { surfaceCells[$0 * width + x] }),
                  let top = (0..<height).last(where: { surfaceCells[$0 * width + x] }) else { continue }
            for y in bottom...top { filled[y * width + x] = true }
        }
        self.cells = filled
    }

    static func make(renderer: BlackHoleRenderer, width: Int = 256, height: Int = 160) throws -> DiskHitMap {
        try make(renderer: renderer, geometry: DropGeometry(spin: renderer.settings.spin,
                                                          inclination: renderer.settings.inclination), width: width, height: height)
    }

    static func make(renderer: BlackHoleRenderer, geometry: DropGeometry, width: Int = 256, height: Int = 160) throws -> DiskHitMap {
        var inputs = [GeodesicProbe]()
        for y in 0..<height {
            for x in 0..<width {
                inputs.append(GeodesicProbe(camera: SIMD4(
                    (Float(x) + 0.5) / Float(width) * 1.6 - 0.8,
                    (Float(y) + 0.5) / Float(height) - 0.5,
                    Float(geometry.spin), Float(geometry.inclination)),
                    options: SIMD4(1, 1, 0, 0)))
            }
        }
        let rays = try renderer.probe(inputs)
        let a = abs(geometry.spin)
        let z1 = 1 + pow(1-a*a, 1.0/3) * (pow(1+a, 1.0/3) + pow(1-a, 1.0/3))
        let z2 = sqrt(3*a*a + z1*z1)
        let inner = 3 + z2 - sqrt(max(0, (3-z1)*(3+z1+2*z2)))
        let cells = rays.map { ray -> Bool in
            if ray[4] == 2 { return true } // The central hole remains a valid release target.
            guard ray[4] == 1 else { return false }
            let radius = Double(ray[0])
            let opacity = 0.96 * smooth(inner, inner + 0.6, radius) * (1 - smooth(14, 23, radius))
            return opacity > 0.08 // Exclude the nearly transparent outer fade and PSF halo.
        }
        return DiskHitMap(width: width, height: height, surfaceCells: cells)
    }

    func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0, point.x.isFinite, point.y.isFinite,
              point.x >= rect.minX, point.y >= rect.minY,
              point.x < rect.maxX, point.y < rect.maxY else { return false }
        let x = Int((point.x - rect.minX) / rect.width * Double(width))
        let y = Int((point.y - rect.minY) / rect.height * Double(height))
        return cells[y * width + x]
    }

    func samplePoint(in rect: CGRect) -> CGPoint {
        // Pick an actual disk pixel on the right, never assume an ellipse fits.
        for x in stride(from: width * 3 / 4, through: width / 2, by: -1) {
            for y in (height / 2 - 15)...(height / 2 + 15) where cells[y * width + x] {
                return CGPoint(x: rect.minX + (Double(x) + 0.5) / Double(width) * rect.width,
                               y: rect.minY + (Double(y) + 0.5) / Double(height) * rect.height)
            }
        }
        return CGPoint(x: rect.midX, y: rect.midY)
    }
}

struct DropGeometry: Equatable {
    let spin: Double
    let inclination: Double
}

func bounded(_ value: Double) -> Double { min(1, max(0, value)) }
func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
    let p = bounded((value - a) / (b - a))
    return p * p * (3 - 2 * p)
}

struct DropPose {
    let point: CGPoint
    let rotation: Double
    let scaleX: Double
    let scaleY: Double
    let alpha: Double
}

enum DropMotion {
    static let duration = 1.18
    static let fractureTime = 0.38

    static func jitter(time: Double, proximity: Double, reduced: Bool) -> CGPoint {
        guard !reduced else { return .zero }
        let amplitude = 1.5 + 2.8 * bounded(proximity)
        return CGPoint(x: amplitude * (sin(time * 79) + 0.32 * sin(time * 137)),
                       y: amplitude * (cos(time * 91) + 0.25 * sin(time * 113)))
    }

    static func pose(start: CGPoint, center: CGPoint, time: Double) -> DropPose {
        let p = bounded(time / 0.92)
        let radius = 1 - p * p
        let angle = -1.35 * p * p
        let dx = start.x - center.x, dy = start.y - center.y
        let point = CGPoint(x: center.x + (dx * cos(angle) - dy * sin(angle)) * radius,
                            y: center.y + (dx * sin(angle) + dy * cos(angle)) * radius)
        return DropPose(point: point, rotation: angle - p * 0.5,
                        scaleX: (1 - 0.8 * p) * (1 + 0.6 * sin(p * .pi)),
                        scaleY: (1 - 0.84 * p), alpha: 1 - smooth(0.30, 0.43, time))
    }

    static func fragment(start: CGPoint, center: CGPoint, index: Int, time: Double) -> DropPose {
        let onset = fractureTime + Double(index % 5) * 0.012
        let p = bounded((time - onset) / (0.60 + Double(index % 7) * 0.018))
        let base = pose(start: start, center: center, time: fractureTime)
        let row = index / 5, col = index % 5
        let ox = (Double(col) - 2) * (64.0 / 5) * base.scaleX
        let oy = (Double(row) - 2.5) * (64.0 / 6) * base.scaleY
        let dx = base.point.x + ox * cos(base.rotation) - oy * sin(base.rotation) - center.x
        let dy = base.point.y + ox * sin(base.rotation) + oy * cos(base.rotation) - center.y
        let twist = -p * (1.9 + Double(index % 3) * 0.2)
        let radius = pow(1 - p, 1.35)
        let point = CGPoint(x: center.x + (dx * cos(twist) - dy * sin(twist)) * radius,
                            y: center.y + (dx * sin(twist) + dy * cos(twist)) * radius)
        return DropPose(point: point, rotation: base.rotation + twist * 2 + Double(index % 3 - 1) * p,
                        scaleX: base.scaleX * (1 + 1.7 * sin(.pi * p)) * (1 - p),
                        scaleY: base.scaleY * (1 - p) * (1 - 0.6 * p),
                        alpha: smooth(0.30, onset + 0.04, time) * (1 - smooth(0.72, 1, p)))
    }
}

enum DropPhase: String { case idle, hovering, falling }

final class DropInteraction {
    private(set) var phase = DropPhase.idle
    private(set) var point = CGPoint.zero
    private(set) var tokens = [DropToken]()
    private(set) var started = 0.0
    private(set) var completed = 0
    private(set) var acceptedDrops = 0
    var busy: Bool { phase == .falling }

    @discardableResult
    func hover(point: CGPoint, tokens: [DropToken], inside: Bool, time: Double) -> Bool {
        guard !busy else { return false }
        guard inside, !tokens.isEmpty else { cancel(); return false }
        if phase != .hovering { started = time }
        self.point = point; self.tokens = Array(tokens.prefix(32)); phase = .hovering
        return true
    }

    @discardableResult
    func release(time: Double) -> Bool {
        guard phase == .hovering else { return false }
        phase = .falling; started = time; acceptedDrops += 1
        return true
    }

    func cancel() {
        guard !busy else { return }
        phase = .idle; tokens = []
    }

    func reset() { phase = .idle; tokens = [] }

    func advance(time: Double, reduced: Bool) {
        guard busy, time - started >= (reduced ? 0.32 : DropMotion.duration + Double(min(3, tokens.count) - 1) * 0.09) else { return }
        completed += 1; reset()
    }
}
