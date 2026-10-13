// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal

// Generated pixels only. No DesktopCapture instance, permission request,
// ScreenCaptureKit enumeration, or live desktop frame enters this validation.
func runDesktopChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer {
        settings.desktopLensing=false;settings.desktopStrength=0.65
        renderer.syntheticDesktop=nil;renderer.desktopFrameProvider=nil;renderer.desktopRect=SIMD4(0,0,1,1);renderer.desktopViewport=SIMD4(0,0,1,1)
        settings.restoreAppearance()
    }
    let w=1280,h=800
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:w,height:h,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage = .shaderRead
    guard let grid=renderer.device.makeTexture(descriptor:descriptor) else {throw RenderError.unavailable("无法创建合成桌面测试纹理。")}
    var pixels=[UInt8](repeating:255,count:w*h*4)
    for y in 0..<h {for x in 0..<w {
        let i=(y*w+x)*4,checker=((x/64+y/64)%2)==0
        pixels[i]=checker ? 200:125;pixels[i+1]=checker ? 211:143;pixels[i+2]=checker ? 225:167
        if x%64<3 || y%64<3 {pixels[i]=40;pixels[i+1]=70;pixels[i+2]=120}
        if abs(x-w/2)<3 {pixels[i]=40;pixels[i+1]=220;pixels[i+2]=70}
        if abs(y-h/2)<3 {pixels[i]=230;pixels[i+1]=60;pixels[i+2]=40}
    }}
    pixels.withUnsafeBytes {grid.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
    var liveProviderCalls=0
    renderer.desktopFrameProvider={liveProviderCalls+=1;return nil}
    let plain=try renderer.snapshot(to:output.appendingPathComponent("desktop-disabled.png"),width:w,height:h)
    var checks=["default_capture_disabled":!settings.desktopLensing]
    settings.desktopLensing=true;renderer.syntheticDesktop=grid;settings.desktopStrength=0
    let identity=try renderer.snapshot(to:output.appendingPathComponent("desktop-grid-before.png"),width:w,height:h,background:3)
    let zero=try renderer.snapshot(to:output.appendingPathComponent("desktop-zero-strength.png"),width:w,height:h)
    checks["zero_strength_preserves_overlay"]=zero==plain
    settings.desktopStrength=0.65
    let warped=try renderer.snapshot(to:output.appendingPathComponent("desktop-grid-after.png"),width:w,height:h,background:3)
    let transparent=try renderer.snapshot(to:output.appendingPathComponent("desktop-warp-transparent.png"),width:w,height:h)
    let map=try renderer.desktopMappingForValidation()
    let maps=renderer.desktopMapBuildCount,geometry=renderer.geometryBuildCount
    let repeatFrame=try renderer.snapshot(to:output.appendingPathComponent("desktop-grid-repeat.png"),width:w,height:h,background:3)
    var changed=0,opaqueChanges=0,edgeChanges=0,badAlpha=0
    for p in 0..<(w*h) {
        let i=p*4,x=p%w,y=p/w
        let difference=(0..<3).map{abs(Int(warped[i+$0])-Int(identity[i+$0]))}.max()!
        if difference>8 && plain[i+3]<220 {changed+=1}
        if plain[i+3]==255 && difference>2 {opaqueChanges+=1}
        if x<3 || x>w-4 || y<3 || y>h-4 {
            if difference>0 || transparent[i+3] != plain[i+3] {edgeChanges+=1}
        }
        if max(transparent[i],transparent[i+1],transparent[i+2])>transparent[i+3] {badAlpha+=1}
    }
    checks["visible_desktop_deflection"]=changed>10000
    checks["opaque_disk_and_shadow_occlude_desktop"]=opaqueChanges==0
    checks["disk_envelope_leaves_all_panel_edges_unchanged"]=edgeChanges==0
    checks["valid_premultiplied_desktop"]=badAlpha==0
    checks["deterministic_desktop_render"]=warped==repeatFrame
    checks["kerr_desktop_rays_finite_and_terminated"]=map.allSatisfy{v in (0..<4).allSatisfy{v[$0].isFinite} && [0.0,2.0,3.0].contains(v.z)}
    let captured=map.filter{$0.z==2}.count,escaped=map.filter{$0.z==3}.count
    checks["capture_and_escape_paths_exercised"]=captured>1000 && escaped>10000
    // Ignoring disk intersections for the background map must not add a second
    // shadow mask in the foreground disk's partially covered/transparent gaps.
    var exposedCaptured=0,capturedOverlayChanges=0
    for p in 0..<(w*h) where map[p].z==2 {
        if plain[p*4+3]<250 {exposedCaptured+=1}
        if (0..<4).contains(where:{transparent[p*4+$0] != plain[p*4+$0]}) {capturedOverlayChanges+=1}
    }
    checks["foreground_gaps_exercise_captured_background"]=exposedCaptured>500
    checks["captured_background_preserves_foreground_rgba"]=capturedOverlayChanges==0
    var outerChanges=0,outerPixels=0,maxMixedDisplacement:Float=0,mixedSamples=0
    for p in 0..<(w*h) {
        let x=(Float(p%w)+0.5)/Float(w)-0.5,y=(Float(p/w)+0.5)/Float(h)-0.5
        if sqrt(x*x+y*y)*2>=0.94 {
            outerPixels+=1
            if (0..<4).contains(where:{warped[p*4+$0] != identity[p*4+$0]}) {outerChanges+=1}
        }
    }
    checks["disk_envelope_excludes_distant_window_corners"]=outerPixels>100000 && outerChanges==0
    // Include a subpixel-strength case to exercise the alpha handoff as well
    // as the radial transition at ordinary strengths.
    for strength in [0.001,0.01,0.0725,0.65,1.0] {
        settings.desktopStrength=strength
        let lookup=try renderer.desktopLookupForValidation()
        for p in 0..<lookup.count where map[p].z==3 && lookup[p].z>0 && lookup[p].z<0.9999 {
            mixedSamples+=1;maxMixedDisplacement=max(maxMixedDisplacement,lookup[p].w)
        }
        checks["bounded_sources_\(strength)"]=lookup.allSatisfy {v in
            (0..<4).allSatisfy{v[$0].isFinite} && v.x>=0 && v.x<=1 && v.y>=0 && v.y<=1 && v.z>=0 && v.z<=1
        }
        checks["captured_background_has_no_extra_mask_\(strength)"]=(0..<map.count).allSatisfy {map[$0].z != 2 || lookup[$0].z==0}
    }
    checks["no_resolved_double_image_in_alpha_transition"]=mixedSamples>100 && maxMixedDisplacement<=0.351
    settings.desktopStrength=0.0725
    _ = try renderer.snapshot(to:output.appendingPathComponent("desktop-grid-strength-7.png"),width:w,height:h,background:3)
    renderer.desktopRect=SIMD4(0.1,0.15,0.7,0.65);settings.desktopStrength=0.9
    _ = try renderer.snapshot(to:output.appendingPathComponent("desktop-grid-moved.png"),width:w,height:h,background:3)
    checks["moving_and_strength_reuse_geometry"]=renderer.desktopMapBuildCount==maps && renderer.geometryBuildCount==geometry
    settings.desktopStrength=0
    let movedLookup=try renderer.desktopLookupForValidation()
    var movedOuterError:Float=0
    for p in 0..<movedLookup.count {
        let uv=SIMD2((Float(p%w)+0.5)/Float(w),(Float(p/w)+0.5)/Float(h))
        let dx=(uv.x-0.5)*2,dy=(uv.y-0.5)*2
        if sqrt(dx*dx+dy*dy)>=0.94 {
            let expected=SIMD2<Float>(0.1,0.15)+uv*SIMD2<Float>(0.7,0.65)
            movedOuterError=max(movedOuterError,max(abs(movedLookup[p].x-expected.x),abs(movedLookup[p].y-expected.y)))
        }
    }
    checks["zero_strength_moved_coordinates_match_screen"]=movedOuterError<1e-6
    settings.desktopStrength=0.9
    for rect in [SIMD4<Float>(0,0,0.2,0.2),SIMD4<Float>(0.8,0.8,0.2,0.2)] {
        renderer.desktopRect=rect
        let edgeLookup=try renderer.desktopLookupForValidation()
        checks["screen_edge_sources_\(rect.x)"]=edgeLookup.allSatisfy {$0.x>=0 && $0.x<=1 && $0.y>=0 && $0.y<=1}
    }
    renderer.syntheticDesktop=nil
    let lost=try renderer.snapshot(to:output.appendingPathComponent("desktop-no-frame.png"),width:w,height:h)
    checks["missing_capture_frame_restores_transparency"]=lost==plain
    checks["offscreen_never_reads_live_capture"]=liveProviderCalls==0
    renderer.syntheticDesktop=grid;renderer.desktopRect=SIMD4(0,0,1,1)
    for (spin,angle) in [(-0.998,2.0),(0.998,35.0)] {
        settings.spin=spin;settings.inclination=angle
        _ = try renderer.snapshot(to:output.appendingPathComponent("desktop-boundary-\(spin).png"),width:640,height:400,background:3)
        let boundary=try renderer.desktopMappingForValidation()
        checks["finite_terminated_background_\(spin)"]=boundary.allSatisfy {v in
            (0..<4).allSatisfy{v[$0].isFinite} && [0.0,2.0,3.0].contains(v.z)
        }
    }
    let screen=CGRect(x:-1920,y:-200,width:1920,height:1080)
    let overlay=CGRect(x:-1800,y:100,width:360,height:225)
    let rect=DesktopCoordinates.rect(overlay:overlay,screen:screen)
    let expected=SIMD4<Float>(120/1920,555/1080,360/1920,225/1080)
    checks["desktop_coordinates_negative_origin_and_y_flip"]=(0..<4).allSatisfy{abs(rect[$0]-expected[$0])<1e-6}
    checks["retina_capture_uses_physical_pixels"]=DesktopCoordinates.captureSize(points:CGSize(width:2304,height:1440),pixelScale:2)==CGSize(width:4608,height:2880)
    checks["nonretina_capture_preserves_size"]=DesktopCoordinates.captureSize(points:CGSize(width:1920,height:1080),pixelScale:1)==CGSize(width:1920,height:1080)
    let large=DesktopCoordinates.captureSize(points:CGSize(width:7680,height:4320),pixelScale:2)
    checks["capture_memory_and_aspect_bounded"]=large.width*large.height<=16_777_216 && max(large.width,large.height)<=8192 && abs(large.width/large.height-7680/4320)<0.001
    settings.restoreAppearance();settings.desktopLensing=true;settings.desktopStrength=0.65
    renderer.desktopRect=SIMD4(0,0,1,1)
    _ = try renderer.snapshot(to:output.appendingPathComponent("desktop-native-composite.png"),width:720,height:450,background:3,sceneSize:SIMD2(540,338))
    let nativeLookup=try renderer.desktopLookupForValidation(),diskGeometry=try renderer.geometryDiagnostics()
    let diskCount=["captured","disk","escaped","budget_exhausted","nonfinite"].reduce(0){$0+(diskGeometry[$1] as? Int ?? 0)}
    checks["native_composite_keeps_selected_disk_resolution"]=nativeLookup.count==720*450 && diskCount==540*338
    // A spatially uniform background cannot change under a coordinate warp.
    // Compare the entire frame, including the lower gap, at independent scene
    // and output resolutions. These blue pixels are generated, never captured.
    guard let blue=renderer.device.makeTexture(descriptor:descriptor) else {throw RenderError.unavailable("无法创建蓝色测试纹理。")}
    for p in 0..<(w*h) {pixels[p*4]=55;pixels[p*4+1]=140;pixels[p*4+2]=190;pixels[p*4+3]=255}
    pixels.withUnsafeBytes {blue.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
    renderer.syntheticDesktop=blue
    var blueErrors=[String:Int]()
    for spin in [0.0,0.6] {
        settings.spin=spin;settings.desktopStrength=0
        let blueBaseline=try renderer.snapshot(to:output.appendingPathComponent("desktop-blue-reference-\(spin).png"),width:960,height:600,background:3,sceneSize:SIMD2(720,450))
        for strength in [0.1171875,0.65,1.0] {
            settings.desktopStrength=strength
            let blueWarped=try renderer.snapshot(to:output.appendingPathComponent("desktop-blue-lensing-\(spin)-\(strength).png"),width:960,height:600,background:3,sceneSize:SIMD2(720,450))
            let error=zip(blueBaseline,blueWarped).map{abs(Int($0)-Int($1))}.max() ?? 0
            let key="spin_\(spin)_strength_\(strength)"
            blueErrors[key]=error
            checks["uniform_background_preserves_appearance_\(key)"]=error<=1
        }
    }
    checks["offscreen_never_reads_live_capture"]=liveProviderCalls==0
    let fullDisplay=try runFullDisplayChecks(renderer:renderer,grid:grid,output:output)
    checks.merge(fullDisplay.checks,uniquingKeysWith: {_,new in new})
    let drag=try runDesktopDragChecks(settings:settings,grid:grid,output:output)
    checks.merge(drag.checks,uniquingKeysWith: {_,new in new})
    let report:[String:Any]=["checks":checks,"drag":drag.metrics,"full_display":fullDisplay.metrics,"changed_background_pixels":changed,"opaque_changed_pixels":opaqueChanges,
        "exposed_captured_background_pixels":exposedCaptured,"captured_overlay_changed_pixels":capturedOverlayChanges,
        "uniform_background_max_channel_error":blueErrors,
        "edge_changed_pixels":edgeChanges,"captured_background_rays":captured,"escaped_background_rays":escaped,
        "old_ellipse_exterior_pixels":outerPixels,"old_ellipse_exterior_changed_pixels":outerChanges,"max_mixed_source_displacement_px":maxMixedDisplacement,
        "mixed_samples":mixedSamples,"moved_outer_max_uv_error":movedOuterError,
        "note":"Generated pixels only. A fitted disk and central-arc envelope feathers displacement back to identity. The live background surface stays fixed in display coordinates; local scissoring bounds shading work. Kerr cache coordinates remain isotropic. Real desktop pixels, native drag timing, multi-display operation and sustained performance are not covered."]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("desktop-lensing.json"),options:.atomic)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("桌面引力透镜检查失败，详见 desktop-lensing.json。")}
}
