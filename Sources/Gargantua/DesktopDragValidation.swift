// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal

// Generated pixels only. This checks moving coordinate transforms and backing
// sizes, not WindowServer presentation timing or the user's real desktop.
func runDesktopDragChecks(settings: Settings, grid: MTLTexture, output: URL) throws -> (checks:[String:Bool],metrics:[String:Any]) {
    settings.restoreAppearance();settings.desktopLensing=true;settings.spin=0.6;settings.desktopStrength=1
    let local=try BlackHoleRenderer(settings:settings,backgroundOnly:true)
    let reference=try BlackHoleRenderer(settings:settings,backgroundOnly:true)
    let stationary=try BlackHoleRenderer(settings:settings,backgroundOnly:true)
    reference.useDesktopScissor=false
    local.syntheticDesktop=grid;reference.syntheticDesktop=grid
    stationary.syntheticDesktop=grid
    let screen=CGRect(x:0,y:0,width:1280,height:800)
    let offsets:[CGFloat]=[0,0.125,0.25,0.375,0.5,0.75,1,2.5,5,8,13,21,34,55,80,120,200,-120,0]
    var sizes=Set<String>(),legacySizes=Set<String>()
    var worst=0,oldTextureMismatch=0,outsideAlpha=0,scissorError=0,stalePixels=0
    var previous=[UInt8](),previousSize=CGSize.zero
    var firstBuilds=0
    for (index,offset) in offsets.enumerated() {
        let hole=CGRect(x:470+offset,y:290+offset*0.25,width:320.375,height:320.375/1.6)
        let frame=DesktopField.frame(overlay:hole,screen:screen,pixelScale:1)
        let width=Int(frame.width),height=Int(frame.height)
        sizes.insert("\(width)x\(height)")
        let r=CGFloat(0.76)*hole.height // v0.9.1 circular-window regression fixture
        legacySizes.insert("\(Int(ceil(hole.midX+r)-floor(hole.midX-r)))x\(Int(ceil(hole.midY+r)-floor(hole.midY-r)))")
        local.desktopRect=DesktopCoordinates.rect(overlay:frame,screen:screen)
        local.desktopViewport=DesktopCoordinates.rect(overlay:hole,screen:frame)
        reference.desktopViewport=DesktopCoordinates.rect(overlay:hole,screen:screen)
        stationary.desktopViewport=reference.desktopViewport
        let actual=try local.snapshot(to:output.appendingPathComponent("drag-local-latest.png"),width:width,height:height)
        let expected=try reference.snapshot(to:output.appendingPathComponent("drag-global-latest.png"),width:1280,height:800)
        let fixed=try stationary.snapshot(to:output.appendingPathComponent("drag-stationary-latest.png"),width:1280,height:800,reuseTarget:true)
        for p in 0..<(1280*800) {
            for c in 0..<4 {scissorError=max(scissorError,abs(Int(fixed[p*4+c])-Int(expected[p*4+c])))}
            if expected[p*4+3]==0 && fixed[p*4+3] != 0 {stalePixels+=1}
        }
        if index==0 {firstBuilds=local.desktopMapBuildCount}
        let x0=Int(frame.minX),y0=Int(screen.maxY-frame.maxY)
        for y in 0..<height {for x in 0..<width {
            let i=(y*width+x)*4,j=((y0+y)*1280+x0+x)*4
            for c in 0..<4 {worst=max(worst,abs(Int(actual[i+c])-Int(expected[j+c])))}
            if previousSize==frame.size && (0..<4).contains(where:{abs(Int(previous[i+$0])-Int(expected[j+$0]))>8}) {
                oldTextureMismatch+=1
            }
        }}
        for y in 0..<800 {for x in 0..<1280 {
            if x<x0 || x>=x0+width || y<y0 || y>=y0+height {
                if expected[(y*1280+x)*4+3] != 0 {outsideAlpha+=1}
            }
        }}
        previous=actual;previousSize=frame.size
    }
    var retinaSizes=Set<String>(),retinaLegacy=Set<String>()
    for step in 0..<64 {
        let p=CGFloat(step)/8,hole=CGRect(x:600+p,y:300+p*0.5,width:626.4912836767037,height:626.4912836767037/1.6)
        let frame=DesktopField.frame(overlay:hole,screen:screen,pixelScale:2)
        retinaSizes.insert("\(frame.width)x\(frame.height)")
        let r=CGFloat(0.76)*hole.height
        retinaLegacy.insert("\(ceil((hole.midX+r)*2)-floor((hole.midX-r)*2))x\(ceil((hole.midY+r)*2)-floor((hole.midY-r)*2))")
    }
    let checks=["drag_crop_matches_global_coordinates":worst<=2,
                "drag_keeps_drawable_size_stable":sizes.count==1 && retinaSizes.count==1,
                "drag_fixture_detects_previous_resize_oscillation":legacySizes.count>1 && retinaLegacy.count>1,
                "drag_reuses_same_ray_cache":local.desktopMapBuildCount==firstBuilds,
                "drag_preserves_local_effect_range":outsideAlpha==0,
                "drag_fixture_detects_stale_texture_translation":oldTextureMismatch>1000,
                "stationary_local_scissor_matches_unrestricted_render":scissorError==0,
                "stationary_reused_target_clears_old_lens_position":stalePixels==0,
                "stationary_movement_reuses_ray_cache":stationary.desktopMapBuildCount==1]
    return (checks,["frames":offsets.count,"max_crop_reference_channel_error":worst,
                    "legacy_translated_texture_mismatch_pixels":oldTextureMismatch,"outside_surface_nontransparent_pixels":outsideAlpha,
                    "drawable_sizes":sizes.sorted(),"retina_drawable_sizes":retinaSizes.sorted(),
                    "legacy_size_count":legacySizes.count,"legacy_retina_size_count":retinaLegacy.count,
                    "ray_cache_builds":local.desktopMapBuildCount,
                    "stationary_scissor_max_channel_error":scissorError,"stationary_stale_pixels":stalePixels,
                    "stationary_ray_cache_builds":stationary.desktopMapBuildCount,
                    "note":"Generated moving-frame comparison only; does not assert native drag presentation timing."])
}
