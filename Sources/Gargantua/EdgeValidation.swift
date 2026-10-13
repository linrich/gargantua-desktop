// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Compare actual finite-area shadow coverage with an independent 8x8 uniform
// grid that also samples pixels outside the adaptive detector's selected band.
func runEdgeChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer {renderer.edgeGrid=4;renderer.shadowCoverageDiagnostic=false;settings.restoreAppearance()}
    renderer.shadowCoverageDiagnostic=true
    var cases=[[String:Any]]()
    for (spin,angle) in [(0.6,8.0),(-0.998,2.0)] {
        settings.spin=spin;settings.inclination=angle
        var images=[[SIMD4<Float>]]()
        for grid in [2,4,8] {
            renderer.edgeGrid=grid
            _ = try renderer.snapshot(to:output.appendingPathComponent("coverage-\(spin)-\(grid).png"),width:192,height:120,background:2)
            images.append(try renderer.scenePixels())
            let d=try renderer.geometryDiagnostics()
            guard (d["refinement_overflow"] as? Int)==0,(d["refined_invalid"] as? Int)==0 else {
                throw RenderError.unavailable("边缘超采样缓存或积分检查失败。")
            }
        }
        let edgePixels=images[2].indices.filter {i in
            let a=images[2][i].w
            return (a>0 && a<1) || images[0][i].w != a || images[1][i].w != a
        }
        func coverageError(_ image:[SIMD4<Float>])->Double {
            edgePixels.reduce(0.0) {$0+abs(Double(image[$1].w-images[2][$1].w))}/Double(max(1,edgePixels.count))
        }
        let old=coverageError(images[0]),new=coverageError(images[1])
        let levels=Set(images[1].map {$0.w}.filter {$0>0 && $0<1}).count
        cases.append(["spin":spin,"inclination":angle,"edge_pixels":edgePixels.count,
                      "previous_2x2_coverage_mae":old,"adaptive_4x4_coverage_mae":new,
                      "fractional_coverage_levels":levels,"reference":"8x8 every pixel, same Kerr integrator"])
        guard edgePixels.count>50,new<old*0.8,levels>3 else {
            throw RenderError.unavailable("边界覆盖没有得到预期改善：旧误差 \(old)，新误差 \(new)。")
        }
    }
    renderer.edgeGrid=4;renderer.shadowCoverageDiagnostic=false;settings.restoreAppearance()
    // Maximum native Retina size: keep the full optical path enabled.
    _ = try renderer.snapshot(to:output.appendingPathComponent("retina-3840.png"),width:RenderDetail.maximumWidth,height:RenderDetail.maximumHeight,background:1)
    let largest=try renderer.geometryDiagnostics()
    guard (largest["nonfinite"] as? Int)==0,(largest["refined_invalid"] as? Int)==0,
          (largest["budget_exhausted"] as? Int)==0,(largest["refinement_overflow"] as? Int)==0 else {
        throw RenderError.unavailable("最大 Retina 尺寸光路检查失败。")
    }
    let perf=try renderer.benchmark(width:RenderDetail.maximumWidth,height:RenderDetail.maximumHeight,frames:16)
    let result:[String:Any]=["cases":cases,"retina_geometry":largest,"retina_performance":perf,
        "note":"Finite test views, 8x8 quadrature is a convergence reference, not an analytic exact silhouette. Timings are warmed offscreen frames."]
    try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("edge-quality.json"),options:.atomic)
    print("Edge coverage checks: \(cases)")
}
