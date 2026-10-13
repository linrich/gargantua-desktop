// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func runMaterialChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    // Preserve the established rotating-disk continuity fixture; the complete
    // image and defaults checks separately cover the new a=0 startup scene.
    settings.setMovieParameters()
    defer {settings.restoreAppearance();renderer.useReferenceMaterial=false}
    renderer.useReferenceMaterial=true
    let old=try renderer.snapshot(to:output.appendingPathComponent("matter-before.png"),background:1)
    let before=try renderer.materialStatistics(), oldScene=try renderer.scenePixels()
    let geometryCount=renderer.geometryBuildCount
    renderer.useReferenceMaterial=false
    let new=try renderer.snapshot(to:output.appendingPathComponent("matter-after.png"),background:1)
    let after=try renderer.materialStatistics(), newScene=try renderer.scenePixels()
    // Cross each generation boundary from both sides, including negative
    // emission times caused by lookback and a later animation epoch.
    var probes=[SIMD4<Float>]()
    for epoch:Float in [-6,-1,0,1,20,100] {
        for radius:Float in [4.8,8,16] {
            for offset:Float in [-0.0001,0,0.0001,-0.000025,0,0.000025] {
                probes.append(SIMD4(epoch+0.75/20+offset,0.75,radius,0.73))
            }
        }
    }
    let samples=try renderer.materialEvolutionSamples(probes)
    var maxJump:Float=0,smallJump:Float=0
    for i in stride(from:0,to:samples.count,by:6) {
        for c in 0..<3 {
            maxJump=max(maxJump,abs(samples[i][c]-samples[i+1][c]),abs(samples[i+2][c]-samples[i+1][c]))
            smallJump=max(smallJump,abs(samples[i+3][c]-samples[i+4][c]),abs(samples[i+5][c]-samples[i+4][c]))
        }
    }
    let evolutionFinite=samples.allSatisfy {p in (0..<3).allSatisfy {p[$0].isFinite && p[$0]>=0}}
    let materialCount=renderer.materialBuildCount
    let changed=stride(from:0,to:new.count,by:4).filter {abs(Int(new[$0])-Int(old[$0]))>8}.count
    let shadowPreserved=zip(oldScene,newScene).allSatisfy {$1.w >= $0.w}
    let matterBlocksBackground=zip(oldScene,newScene).filter {$0.w==0 && $1.w>0.8}.count
    let repeatFrame=try renderer.snapshot(to:output.appendingPathComponent("matter-repeat.png"),background:1)
    _ = try renderer.snapshot(to:output.appendingPathComponent("matter-motion.png"),time:14,background:1)
    // Brightness/color changes and animation should reuse both geometry and material.
    settings.brightness=1.95; settings.glow=0.93
    _ = try renderer.snapshot(to:output.appendingPathComponent("matter-bright.png"),background:1)
    settings.setPalette(.blue)
    _ = try renderer.snapshot(to:output.appendingPathComponent("matter-blue.png"),background:1)
    let cached=renderer.materialBuildCount == materialCount && renderer.geometryBuildCount == geometryCount
    settings.setPalette(.gold); settings.brightness=1.3;settings.glow=0.65;settings.inclination=25
    _ = try renderer.snapshot(to:output.appendingPathComponent("matter-inclined.png"),background:1)
    let checks=["finite_nonnegative":after["invalid_channels"]==0,
                "azimuthal_structure_increased":after["mean_azimuthal_contrast"]!>1.5*before["mean_azimuthal_contrast"]!,
                "dark_gaps_present":after["dark_area_fraction"]!>0.04,
                "no_exceptional_seam":after["seam_step_to_neighbor_step"]!<3,
                "visible_material_change":changed>10_000,
                "captured_shadow_preserved":shadowPreserved,
                "matter_blocks_bright_background":matterBlocksBackground>10_000,
                "cloud_generation_continuity":evolutionFinite && maxJump<0.1 && smallJump<maxJump*0.55+0.00001,
                "deterministic_material":new==repeatFrame,
                "animation_and_color_reuse_caches":cached]
    let report:[String:Any]=["checks":checks,"old_material":before,"new_material":after,"changed_pixels":changed,
                            "generation_boundary_probes":samples.count,"boundary_delta_1e-4":maxJump,
                            "boundary_delta_2_5e-5":smallJump,"disk_opacity_pixels":matterBlocksBackground,
                            "spin":0.6,"note":"Rotating-disk fixture. Procedural appearance checks; contrast and dark gaps do not validate fluid physics or dust radiative transfer."]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("disk-matter.json"),options:.atomic)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("盘材质或缓存检查失败，详见 disk-matter.json。")}
}
