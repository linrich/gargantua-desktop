// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func runDetailChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer {renderer.useLegacyDetail=false;renderer.lens.useReferenceCore=false;settings.restoreAppearance()}
    settings.size=1400;settings.inclination=25;settings.shutterAngle=0
    let w=2800,h=1750
    renderer.useLegacyDetail=true
    let old=try renderer.snapshot(to:output.appendingPathComponent("detail-before.png"),width:w,height:h,background:1)
    let geometry=renderer.geometryBuildCount
    renderer.useLegacyDetail=false
    let new=try renderer.snapshot(to:output.appendingPathComponent("detail-after.png"),width:w,height:h,background:1)
    let resolution=renderer.materialResolution
    let materialBuilds=renderer.materialBuildCount
    let repeated=try renderer.snapshot(to:output.appendingPathComponent("detail-repeat.png"),width:w,height:h,background:1)
    let statistics=try renderer.sceneStatistics()
    // High-pass contrast in luminous, unsaturated disk interiors. Exclude the
    // silhouette/alpha boundary and use the same mask for both images.
    let scene=try renderer.scenePixels()
    var beforeEnergy=0.0,afterEnergy=0.0,count=0,changed=0
    for y in 2..<(h-2) {for x in 2..<(w-2) {
        let p=y*w+x,i=p*4
        if abs(Int(old[i])-Int(new[i]))>3 {changed+=1}
        let neighbours=[p-1,p+1,p-w,p+w]
        if scene[p].w<0.85 || scene[p].x<0.04 || old[i]<15 || old[i]>230 || new[i]>230 {continue}
        if neighbours.contains(where:{scene[$0].w<0.85 || scene[$0].x<0.04}) {continue}
        func contrast(_ image:[UInt8])->Double {
            let center=Double(image[i])
            return abs(center-neighbours.reduce(0.0){$0+Double(image[$1*4])}/4)
        }
        beforeEnergy+=contrast(old);afterEnergy+=contrast(new);count+=1
    }}
    var checks=["large_material_8192x4096":resolution == [8192,4096],
                "detail_does_not_retrace_geometry":renderer.geometryBuildCount==geometry,
                "same_tier_reuses_material":renderer.materialBuildCount==materialBuilds,
                "deterministic_detail":new==repeated,
                "finite_detail":statistics["invalid_pixels"]==0,
                "resolved_interior_contrast_increased":count>10000 && afterEnergy>beforeEnergy*1.05,
                "visible_detail_change":changed>1000,
                "brightness_upper_bound_doubled":RenderDetail.brightnessRange.upperBound==5,
                "scatter_upper_bound_doubled":RenderDetail.glowRange.upperBound==3]
    // Actual GPU rebuild at each tier, then release the large material on shrink.
    var tiers=[[String:Any]]()
    for width in [540,1140,1600,2800,540] {
        _ = try renderer.snapshot(to:output.appendingPathComponent("detail-tier-\(width).png"),width:width,height:Int(Double(width)/1.6),background:1)
        let expected=RenderDetail.materialWidth(for:width)
        checks["tier_\(width)"]=renderer.materialResolution == [expected,expected/2]
        tiers.append(["output_width":width,"material":renderer.materialResolution])
    }
    settings.restoreAppearance()
    settings.brightness=2.5
    let previousBrightness=try renderer.snapshot(to:output.appendingPathComponent("brightness-2_5.png"),width:720,height:450)
    settings.brightness=5
    let higherBrightness=try renderer.snapshot(to:output.appendingPathComponent("brightness-5.png"),width:720,height:450)
    func redSum(_ image:[UInt8])->Double {stride(from:0,to:image.count,by:4).reduce(0.0){$0+Double(image[$1])}}
    checks["expanded_brightness_changes_gpu_output"]=redSum(higherBrightness)>redSum(previousBrightness)*1.05
    settings.brightness=1.3;settings.glow=1.5
    let previousScatter=try renderer.snapshot(to:output.appendingPathComponent("scatter-1_5.png"),width:720,height:450)
    settings.glow=3
    let higherScatter=try renderer.snapshot(to:output.appendingPathComponent("scatter-3.png"),width:720,height:450)
    checks["expanded_scatter_changes_gpu_output"]=zip(previousScatter,higherScatter).filter{abs(Int($0)-Int($1))>2}.count>1000
    let (_,a)=LensResponse.synthesized(height:800,glow:2,scale:1)
    let (_,b)=LensResponse.synthesized(height:800,glow:3,scale:1)
    checks["scatter_not_saturated_above_2"]=a != b
    checks["maximum_scatter_psf_normalized_nonnegative"]=b.allSatisfy{$0.isFinite && $0>=0} && abs(b.reduce(0,+)-1)<0.0001
    let report:[String:Any]=["checks":checks,"tiers":tiers,"changed_pixels":changed,
        "interior_pixels":count,"before_mean_highpass":beforeEnergy/Double(max(1,count)),
        "after_mean_highpass":afterEnergy/Double(max(1,count)),
        "contrast_ratio":afterEnergy/max(1e-9,beforeEnergy),
        "note":"Same 2800x1750 geometry, lens and beam filtering enabled, 25-degree view, zero shutter. Interior high-pass is a detail diagnostic, not a physical accuracy metric. The comparison changes material resolution/detail and only the synthetic PSF core."]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("adaptive-detail.json"),options:.atomic)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("大尺寸细节或亮度范围检查失败，详见 adaptive-detail.json。")}
}
