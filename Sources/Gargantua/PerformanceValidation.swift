// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Offscreen generated scenes only. Neither path requests screen capture or
// touches persistent settings. The baseline is the v0.9.3 FFT pass schedule,
// with the same padding, shared-memory FFT, beam filtering and optical core.
func runFusedLensChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings = renderer.settings
    defer { settings.restoreAppearance(); renderer.lens.useFusedPasses = true }
    func save(_ value: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }
    var numerical = [[String: Any]]()
    for fused in [false, true] {
        renderer.lens.useFusedPasses = fused
        let result = try renderer.checkLensConvolution()
        numerical.append(["fused": fused, "result": result])
        guard (result["checks"] as? [String: Bool])?.values.allSatisfy({ $0 }) == true else {
            try save(numerical, "fused-lens-numerical.json")
            throw RenderError.unavailable("合并镜头通道的独立 CPU 卷积对照失败。")
        }
    }
    try save(numerical, "fused-lens-numerical.json")
    var images = [[String: Any]]()
    for (name, w, h) in [("small",540,338), ("medium",1140,713), ("current-size",1635,1022), ("wide-psf",2400,1500),
                         ("maximum",3840,2400), ("measured",531,333), ("lens-off",720,450)] {
        settings.restoreAppearance()
        if name == "small" || name == "medium" { settings.spin = 0.6; settings.brightness = 5; settings.glow = 1.478209 }
        if name == "current-size" { settings.brightness = 5; settings.glow = 1.478209 }
        if name == "wide-psf" { settings.lensScale = 2; settings.glow = 3; settings.spin = -0.998; settings.inclination = 2 }
        if name == "maximum" { settings.relativistic = true; settings.setPalette(.blue); settings.shutterAngle = 360; settings.speed = 2 }
        if name == "measured" {
            settings.measuredPSF = MeasuredPSF(format: "linear-intensity-psf-v1", size: 5, pitchAt800: 1.7,
                values: [0,0,0.04,0,0, 0,0.02,0.05,0,0, 0.1,0.07,0.5,0.09,0, 0,0.03,0.06,0,0, 0,0,0.04,0,0])
            settings.psfRevision += 1
            settings.setPalette(.violet)
        }
        if name == "lens-off" { settings.lensResponse = false }
        renderer.lens.useFusedPasses = false
        let before = try renderer.snapshot(to: output.appendingPathComponent("fused-before-\(name).png"), width: w, height: h)
        let geometryBuilds = renderer.geometryBuildCount, materialBuilds = renderer.materialBuildCount
        renderer.lens.useFusedPasses = true
        let after = try renderer.snapshot(to: output.appendingPathComponent("fused-after-\(name).png"), width: w, height: h)
        var maximum = 0, squared = 0.0, alphaChanges = 0, changed = 0
        for i in before.indices {
            let d = abs(Int(before[i]) - Int(after[i]))
            maximum = max(maximum, d); squared += Double(d*d)
            if d != 0 { changed += 1; if i % 4 == 3 { alphaChanges += 1 } }
        }
        let rmse = sqrt(squared / Double(before.count))
        let checks = ["equivalent_pixels": maximum <= 1 && rmse < 0.02,
                      "unchanged_alpha": alphaChanges == 0,
                      "geometry_cache_preserved": renderer.geometryBuildCount == geometryBuilds,
                      "material_cache_preserved": renderer.materialBuildCount == materialBuilds]
        images.append(["case": name, "width": w, "height": h, "max_byte_difference": maximum,
                       "rmse_byte": rmse, "changed_channels": changed, "checks": checks])
        try save(images, "fused-lens-equivalence.json")
        guard checks.values.allSatisfy({ $0 }) else { throw RenderError.unavailable("镜头合并图像对照失败：\(name)。") }
        print("镜头画面对照通过：\(name) \(w)×\(h)，max=\(maximum)"); fflush(stdout)
    }
    settings.restoreAppearance()
    settings.spin = 0.6; settings.brightness = 5; settings.glow = 1.478209
    var timings = [[String: Any]]()
    for (w, h, frames) in [(540,338,24), (1140,713,24), (1635,1022,24), (2400,1500,16), (3840,2400,12)] {
        settings.spin = w == 1635 ? 0:0.6
        for lensOnly in [true, false] {
            var before = [Double](), after = [Double]()
            for fused in [false, true, true, false] {
                renderer.lens.useFusedPasses = fused
                let timing = try renderer.benchmark(width: w, height: h, frames: frames, lensOnly: lensOnly)
                let samples = timing["gpu_samples_ms"] as! [Double]
                if fused { after += samples } else { before += samples }
            }
            func summary(_ samples: [Double]) -> [String: Any] {
                let sorted = samples.sorted()
                return ["frames": samples.count, "median_ms": sorted[sorted.count/2],
                        "p95_ms": sorted[Int(Double(sorted.count-1)*0.95)], "samples_ms": samples]
            }
            let old = summary(before), new = summary(after)
            let reduction = 1 - (new["median_ms"] as! Double) / (old["median_ms"] as! Double)
            timings.append(["width": w, "height": h, "spin": settings.spin, "scope": lensOnly ? "lens-only":"full-foreground-frame",
                            "baseline_v093": old, "fused": new, "median_reduction_fraction": reduction])
            try save(["gpu": renderer.device.name, "results": timings,
                      "method": "ABBA; each run warms two frames; unchanged v0.9.3 pass schedule vs fused boundaries and size-selected register butterflies. Same resolution, beam samples, material and full PSF. Spin 0.6 (0 at 1635x1022), brightness 5, glow 1.478209, 180-degree shutter, warm geometry/material/PSF caches. GPU command duration only; excludes live screen capture, WindowServer, initial geometry, sustained power and thermal behavior."], "fused-lens-performance.json")
            print("性能完成：\(w)×\(h) \(lensOnly ? "lens":"frame")，中位耗时变化 \(reduction * 100)%"); fflush(stdout)
        }
    }
}
