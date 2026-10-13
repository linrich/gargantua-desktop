// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func saveCheck(_ value: Any, _ name: String, _ output: URL) throws {
    try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent(name),options:.atomic)
}

func runAppearanceChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer { settings.restoreAppearance(); renderer.lens.useReferenceFFT=false; renderer.useReferenceFiltering=false }
    var comparisons=[[String:Any]]()
    for (name,w,h) in [("default",1280,800),("wide-lens",2400,1500),("cold-relativistic",720,450)] {
        settings.restoreAppearance()
        if name == "wide-lens" { settings.lensScale=2; settings.glow=1.5; settings.spin = -0.998; settings.inclination=2 }
        if name == "cold-relativistic" {settings.relativistic=true; settings.setPalette(.blue); settings.shutterAngle=360;settings.speed=2}
        renderer.lens.useReferenceFFT=true;renderer.useReferenceFiltering=true
        let reference=try renderer.snapshot(to:output.appendingPathComponent("reference-\(name).png"),width:w,height:h)
        renderer.lens.useReferenceFFT=false;renderer.useReferenceFiltering=false
        let optimized=try renderer.snapshot(to:output.appendingPathComponent("optimized-\(name).png"),width:w,height:h)
        var maxDifference=0, squared=0.0, changed=0
        for i in reference.indices {
            let delta=abs(Int(reference[i])-Int(optimized[i]))
            maxDifference=max(maxDifference,delta); squared+=Double(delta*delta)
            if delta>0 {changed+=1}
        }
        let rmse=sqrt(squared/Double(reference.count))
        comparisons.append(["case":name,"width":w,"height":h,"max_byte_difference":maxDifference,
                            "rmse_byte":rmse,"changed_channels":changed])
        guard maxDifference<=3, rmse<0.15 else {
            try saveCheck(comparisons,"optimization-equivalence.json",output)
            throw RenderError.unavailable("优化与参照输出差异过大：\(name)，max \(maxDifference)，RMSE \(rmse)。")
        }
    }
    try saveCheck(comparisons,"optimization-equivalence.json",output)
    settings.restoreAppearance()
    let original=try renderer.snapshot(to:output.appendingPathComponent("color-gold.png"))
    let originalStats=try renderer.sceneStatistics(), builds=renderer.geometryBuildCount
    var colors=[[String:Any]]()
    for palette in DiskPalette.allCases where palette != .gold {
        settings.setPalette(palette)
        let pixels=try renderer.snapshot(to:output.appendingPathComponent("color-\(palette.rawValue).png"))
        let stats=try renderer.sceneStatistics()
        let luminanceError=abs(stats["linear_luminance_sum"]!/originalStats["linear_luminance_sum"]!-1)
        let changed=stride(from:0,to:pixels.count,by:4).filter {abs(Int(pixels[$0])-Int(original[$0]))>3}.count
        let badAlpha=stride(from:0,to:pixels.count,by:4).filter {max(pixels[$0],pixels[$0+1],pixels[$0+2])>pixels[$0+3]}.count
        colors.append(["palette":palette.rawValue,"changed_pixels":changed,"luminance_relative_error":luminanceError,
                       "invalid_pixels":stats["invalid_pixels"]!,"invalid_premultiplication":badAlpha])
        guard changed>1000,luminanceError<0.001,stats["invalid_pixels"]==0,badAlpha==0,
              palette != .silver || stats["max_gray_difference"]==0 else {
            throw RenderError.unavailable("调色光强、灰度或透明合成检查失败。")
        }
    }
    settings.setPalette(.gold)
    let restored=try renderer.snapshot(to:output.appendingPathComponent("color-restored.png"))
    let checks=["restore_is_exact":restored==original,"color_preserves_geometry_cache":renderer.geometryBuildCount==builds]
    try saveCheck(["checks":checks,"palettes":colors],"disk-colors.json",output)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("调色恢复或光路缓存检查失败。")}
}

func runPerformanceComparison(renderer: BlackHoleRenderer, output: URL) throws -> [[String:Any]] {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer {settings.restoreAppearance();renderer.lens.useReferenceFFT=false;renderer.useReferenceFiltering=false}
    var rows=[[String:Any]](), current=[[String:Any]]()
    for (w,h,frames) in [(720,450,12),(1280,800,12),(2400,1500,8)] {
        var baseline=[Double](),optimized=[Double]()
        // ABBA reduces ordering bias; caches and kernels warmed separately.
        for reference in [true,false,false,true] {
            renderer.lens.useReferenceFFT=reference;renderer.useReferenceFiltering=reference
            let result=try renderer.benchmark(width:w,height:h,frames:frames)
            if reference {baseline+=result["gpu_samples_ms"] as! [Double]}
            else {optimized+=result["gpu_samples_ms"] as! [Double]}
        }
        func summary(_ samples:[Double])->[String:Any] {
            let sorted=samples.sorted()
            return ["frames":samples.count,"gpu_median_ms":sorted[sorted.count/2],
                    "gpu_p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],"gpu_samples_ms":samples]
        }
        let before=summary(baseline),after=summary(optimized)
        renderer.lens.useReferenceFFT=true
        let oldLens=try renderer.benchmark(width:w,height:h,frames:12,lensOnly:true)
        renderer.lens.useReferenceFFT=false;renderer.useReferenceFiltering=false
        let newLens=try renderer.benchmark(width:w,height:h,frames:12,lensOnly:true)
        settings.lensResponse=false
        let disk=try renderer.benchmark(width:w,height:h,frames:12)
        settings.lensResponse=true
        rows.append(["width":w,"height":h,"baseline":before,"optimized":after,
                     "lens_baseline":oldLens,"lens_optimized":newLens,"disk_and_composite":disk,
                     "gpu_time_reduction_percent":(1-(after["gpu_median_ms"] as! Double)/(before["gpu_median_ms"] as! Double))*100])
        var result=after;result["width"]=w;result["height"]=h;current.append(result)
    }
    try saveCheck(["gpu":renderer.device.name,"cases":rows,
                   "method":"ABBA, default model, full resolution, beams + 180-degree shutter + PSF enabled. Separate lens-only / disk-and-composite probes are indicative, not additive. Warm caches; excludes UI composition, first geometry build and sustained thermal behavior."],
                  "performance-comparison.json",output)
    return current
}
