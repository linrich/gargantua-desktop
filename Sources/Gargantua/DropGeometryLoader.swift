// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// Only immutable probe inputs and Metal pipeline objects cross this local queue.
// Slider changes invalidate reception immediately; stale results never re-enable it.
final class DropGeometryLoader {
    private let renderer: BlackHoleRenderer
    private let queue = DispatchQueue(label: "local.gargantua.drop-geometry", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var revision = 0
    private(set) var requested: DropGeometry
    private(set) var applied: DropGeometry
    var onResult: ((Result<DiskHitMap, Error>) -> Void)?

    init(renderer: BlackHoleRenderer, geometry: DropGeometry) {
        self.renderer = renderer; requested = geometry; applied = geometry
    }

    @discardableResult
    func update(_ geometry: DropGeometry) -> Bool {
        guard geometry != requested else { return false }
        requested = geometry; revision += 1
        pending?.cancel()
        let ticket = revision, renderer = renderer
        let work = DispatchWorkItem { [weak self] in
            guard let self, ticket == self.revision else { return }
            self.queue.async { [weak self] in
                let result = Result { try DiskHitMap.make(renderer: renderer, geometry: geometry) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, ticket == self.revision else { return }
                    if case .success = result { self.applied = geometry }
                    self.onResult?(result)
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        return true
    }
    deinit { pending?.cancel() }
}
