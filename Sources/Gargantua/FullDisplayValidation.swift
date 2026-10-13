// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal
import simd

// Generated textures and numeric ray coordinates only. Never instantiates
// DesktopCapture or enumerates/captures real windows.
func runFullDisplayChecks(renderer foreground: BlackHoleRenderer, grid: MTLTexture, output: URL) throws -> (checks:[String:Bool],metrics:[String:Any]) {
    let settings=foreground.settings
    settings.restoreAppearance();settings.desktopLensing=true
    let renderer=try BlackHoleRenderer(settings:settings,backgroundOnly:true)
    renderer.syntheticDesktop=grid
    renderer.desktopViewport=SIMD4(0.375,0.375,0.25,0.25)
    let w=1280,h=800,height:Float=200
    var calls=0
    renderer.desktopFrameProvider={calls+=1;return nil}
    settings.desktopStrength=0
    let zero=try renderer.snapshot(to:output.appendingPathComponent("full-display-zero.png"),width:w,height:h)
    let reference=try renderer.snapshot(to:output.appendingPathComponent("full-display-grid-reference.png"),width:w,height:h,background:3)
    settings.desktopStrength=0.12
    let desktop=try renderer.snapshot(to:output.appendingPathComponent("full-display-grid-12.png"),width:w,height:h,background:3)
    let map=try renderer.desktopMappingForValidation()
    let lookup=try renderer.desktopLookupForValidation()
    var checks=["background_surface_has_no_foreground_work":renderer.geometryBuildCount==0,
                "zero_strength_full_display_is_transparent":zero.allSatisfy{$0==0},
                "full_display_rays_finite_and_terminated":map.allSatisfy{v in (0..<4).allSatisfy{v[$0].isFinite} && [2.0,3.0].contains(v.z)},
                "full_display_sources_bounded":lookup.allSatisfy{$0.x>=0 && $0.x<=1 && $0.y>=0 && $0.y<=1}]
    settings.desktopStrength=1
    let strong=try renderer.snapshot(to:output.appendingPathComponent("local-grid-100.png"),width:w,height:h,background:3)
    let strongLookup=try renderer.desktopLookupForValidation()
    settings.desktopStrength=0.12
    var outsideChanged=0,insideChanged=0,outsideSupportSamples=0,maxBoundaryStep:Float=0
    for y in 1..<h-1 {for x in 1..<w-1 {
        let p=y*w+x,i=p*4
        let screen=SIMD2((Float(x)+0.5-Float(w)/2)/height,(Float(h)/2-Float(y)-0.5)/height)
        let edge=DesktopField.distance(screen,inclination:8)
        if edge>=DesktopField.featherOuter {
            outsideSupportSamples+=1
            if (0..<4).contains(where:{strong[i+$0] != reference[i+$0]}) {outsideChanged+=1}
        } else if (0..<3).contains(where:{abs(Int(strong[i+$0])-Int(reference[i+$0]))>3}) {
            insideChanged+=1
        }
        // Inspect the actual two-pixel join. The interior feather deliberately
        // has a gradient; it is not itself a seam.
        if abs(edge-DesktopField.featherOuter)<2/height {
            for q in [p+1,p+w] {
                let baseDelta=SIMD2(Float(q%w-x),Float(q/w-y))
                let sourceDelta=SIMD2(strongLookup[q].x-strongLookup[p].x,strongLookup[q].y-strongLookup[p].y)*SIMD2(Float(w),Float(h))
                maxBoundaryStep=max(maxBoundaryStep,simd_length(sourceDelta-baseDelta))
            }
        }
    }}
    checks["desktop_outside_local_support_is_pixel_identical"]=outsideSupportSamples>900000 && outsideChanged==0
    checks["local_disk_vicinity_still_has_visible_lensing"]=insideChanged>5000
    // At 200 px hole height this tests a two-pixel band of the compact feather.
    checks["local_feather_boundary_is_subpixel"]=maxBoundaryStep<0.25

    // Compare equal camera-plane radii in horizontal, vertical and diagonal
    // directions for spin zero: the 1.6:1 panel must not stretch the lens field.
    func displacement(_ point:SIMD2<Float>) -> SIMD2<Float> {
        let x=Int((Float(w)/2+point.x*height).rounded(.down))
        let y=Int((Float(h)/2-point.y*height).rounded(.down))
        let v=map[y*w+x];return SIMD2(v.x,v.y)
    }
    var symmetryError:Float=0
    for radius:Float in [0.35,0.45,0.55,0.68] {
        let lengths=(0..<8).map {i -> Float in
            let a=Float(i)*Float.pi/4
            return simd_length(displacement(SIMD2(cos(a),sin(a))*radius))
        }
        symmetryError=max(symmetryError,(lengths.max()!-lengths.min()!)/(lengths.reduce(0,+)/8))
    }
    checks["schwarzschild_field_has_no_panel_aspect_stretch"]=symmetryError<0.04

    // Check the cache against direct Kerr rays at dispersed pixels. The cache
    // interpolates a field; this comparison checks that approximation separately.
    var points=[(Int,Int)](),probes=[GeodesicProbe]()
    for y in stride(from:h/2-160,to:h/2+160,by:19) {for x in stride(from:w/2-160,to:w/2+160,by:19) {
        let screen=SIMD2((Float(x)+0.5-Float(w)/2)/height,(Float(h)/2-Float(y)-0.5)/height)
        if simd_length(screen)<0.4 || simd_length(screen)>0.74 {continue}
        points.append((x,y));probes.append(GeodesicProbe(camera:SIMD4(screen.x,screen.y,0,8),options:SIMD4(1,0,0,1)))
    }}
    let rays=try renderer.probe(probes,bundles:true)
    let theta=Float.pi/2-8*Float.pi/180
    let forward = -SIMD3<Float>(sin(theta),0,cos(theta)),up=SIMD3<Float>(-cos(theta),0,sin(theta))
    func project(_ ray: SIMD3<Float>) -> SIMD2<Float> {
        let p=SIMD2(ray.y,simd_dot(ray,up)),length=simd_length(p)
        return length>1e-7 ? p/length*atan2(length,simd_dot(ray,forward))*(1.8/1.04):.zero
    }
    var maxRayError:Float=0
    for i in rays.indices {
        let (x,y)=points[i],p=probes[i].camera,r=rays[i]
        guard r[12]==3 else {throw RenderError.unavailable("外围参照光线未逃逸。")}
        let flat=simd_normalize(1.8*forward+1.04*(SIMD3(0,p.x,0)+up*p.y))
        var expected=project(SIMD3(r[0],r[1],r[2]))-project(flat)
        expected*=min(1,0.65/max(simd_length(expected),1e-6))
        let actual=map[y*w+x]
        maxRayError=max(maxRayError,simd_length(SIMD2(actual.x,actual.y)-expected)*height)
    }
    checks["outer_cache_agrees_with_direct_kerr_rays"]=maxRayError<0.5

    // The production window is cropped to the feather's support. Compare its
    // actual mapping/composition to a full-canvas reference to detect seams,
    // source-coordinate shifts, and accidental stretching after the crop.
    let display=CGRect(x:0,y:0,width:w,height:h),hole=CGRect(x:480,y:300,width:320,height:200)
    let surface=DesktopField.frame(overlay:hole,screen:display,pixelScale:1)
    renderer.desktopRect=DesktopCoordinates.rect(overlay:surface,screen:display)
    renderer.desktopViewport=DesktopCoordinates.rect(overlay:hole,screen:surface)
    let sw=Int(surface.width),sh=Int(surface.height)
    let cropped=try renderer.snapshot(to:output.appendingPathComponent("local-cropped-grid.png"),width:sw,height:sh,background:3)
    var cropError=0
    let originX=Int(surface.minX),originY=Int(display.maxY-surface.maxY)
    for y in 0..<sh {for x in 0..<sw {
        let i=(y*sw+x)*4,j=((originY+y)*w+originX+x)*4
        for c in 0..<4 {cropError=max(cropError,abs(Int(cropped[i+c])-Int(desktop[j+c])))}
    }}
    checks["cropped_surface_matches_global_reference"]=cropError<=2
    checks["background_surface_is_local_and_pixel_aligned"]=surface.width<=hole.width && surface.height<display.height/2 && surface.minX.rounded()==surface.minX
    var bounded=true
    for width:CGFloat in [360,626,760,1600] {
        let screen=CGRect(x:-1920,y:-200,width:1920,height:1080)
        let hole=CGRect(x:screen.minX,y:screen.minY,width:width,height:width/1.6)
        let frame=DesktopField.frame(overlay:hole,screen:screen,pixelScale:2)
        bounded = bounded && screen.contains(frame) && frame.width<=width+1 && frame.height<=width+1
    }
    checks["local_surface_scales_and_clips_to_display"]=bounded
    renderer.desktopRect=SIMD4(0,0,1,1)
    renderer.desktopViewport=SIMD4(0.375,0.375,0.25,0.25)
    _ = try renderer.snapshot(to:output.appendingPathComponent("local-restored-grid.png"),width:w,height:h,background:3)

    let builds=renderer.desktopMapBuildCount
    renderer.desktopViewport.x+=0.1
    _ = try renderer.snapshot(to:output.appendingPathComponent("full-display-moved.png"),width:w,height:h,background:3)
    checks["moving_hole_reuses_full_display_ray_cache"]=renderer.desktopMapBuildCount==builds
    renderer.desktopViewport.x-=0.1

    // WindowServer places the unchanged foreground over the separate background.
    // Compare that composition to a single-pass reference on generated pixels.
    settings.desktopLensing=false
    foreground.syntheticDesktop=nil
    let front=try foreground.snapshot(to:output.appendingPathComponent("full-display-foreground.png"),width:320,height:200)
    settings.desktopLensing=true;foreground.syntheticDesktop=grid
    foreground.desktopViewport=renderer.desktopViewport
    let combined=try foreground.snapshot(to:output.appendingPathComponent("full-display-black-hole-12.png"),width:w,height:h,background:3,sceneSize:SIMD2(320,200))
    var splitError=0
    for y in 0..<h {for x in 0..<w {
        let i=(y*w+x)*4
        for c in 0..<3 {
            var expected=Float(desktop[i+c])
            if x>=480 && x<800 && y>=300 && y<500 {
                let f=((y-300)*320+x-480)*4
                expected=Float(front[f+c])+expected*(1-Float(front[f+3])/255)
            }
            splitError=max(splitError,abs(Int(expected.rounded())-Int(combined[i+c])))
        }
    }}
    checks["separate_background_preserves_foreground_composition"]=splitError<=2
    var covered=0,missed=0,envelopePixels=0,legacyPixels=0
    for y in 0..<200 {for x in 0..<320 {
        let p=SIMD2((Float(x)+0.5-160)/200,(100-Float(y)-0.5)/200)
        let inside=DesktopField.distance(p,inclination:8)<DesktopField.featherOuter
        if inside {envelopePixels+=1}
        if simd_length(p)<0.76 {legacyPixels+=1}
        if front[(y*320+x)*4+3]>=128 {
            covered+=1
            if !inside {missed+=1}
        }
    }}
    checks["compact_envelope_contains_main_disk_and_lensed_arc"]=covered>1000 && missed==0
    checks["compact_envelope_is_less_than_half_old_circle"]=envelopePixels*2<legacyPixels
    checks["envelope_follows_disk_inclination"]=DesktopField.distance(SIMD2(0.45,0.2),inclination:8)>DesktopField.featherOuter
        && DesktopField.distance(SIMD2(0.45,0.2),inclination:35)<0
    settings.spin=0.6;settings.desktopStrength=1
    _ = try foreground.snapshot(to:output.appendingPathComponent("local-black-hole-movie-100.png"),width:w,height:h,background:3,sceneSize:SIMD2(320,200))
    foreground.desktopViewport=SIMD4(0,0,1,1)
    settings.desktopStrength=0.05
    _ = try foreground.snapshot(to:output.appendingPathComponent("disk-envelope-movie-5.png"),width:960,height:600,background:3)
    settings.desktopStrength=1
    _ = try foreground.snapshot(to:output.appendingPathComponent("disk-envelope-movie-100.png"),width:960,height:600,background:3)

    // Local support and physical display boundaries, including a hole close
    // to the corner. Exercise movie spin and both extreme spin directions.
    for (spin,angle) in [(0.6,8.0),(-0.998,2.0),(0.998,35.0)] {
        settings.spin=spin;settings.inclination=angle;settings.desktopStrength=1
        renderer.desktopViewport=SIMD4(0.02,0.03,0.25,0.25)
        _ = try renderer.snapshot(to:output.appendingPathComponent("full-display-corner-\(spin).png"),width:w,height:h,background:3)
        let cornerMap=try renderer.desktopMappingForValidation(),cornerUV=try renderer.desktopLookupForValidation()
        checks["full_display_corner_finite_rays_\(spin)"]=cornerMap.allSatisfy {v in
            (0..<4).allSatisfy{v[$0].isFinite} && [2.0,3.0].contains(v.z)
        }
        checks["full_display_corner_bounded_sources_\(spin)"]=cornerUV.allSatisfy {v in
            (0..<4).allSatisfy{v[$0].isFinite} && v.x>=0 && v.x<=1 && v.y>=0 && v.y<=1
        }
        let clipped=try renderer.snapshot(to:output.appendingPathComponent("disk-scissor-\(spin).png"),width:w,height:h)
        renderer.useDesktopScissor=false
        let unclipped=try renderer.snapshot(to:output.appendingPathComponent("disk-unclipped-\(spin).png"),width:w,height:h)
        renderer.useDesktopScissor=true
        checks["disk_scissor_keeps_complete_contour_\(spin)"]=clipped==unclipped
    }
    settings.spin=0.6;settings.inclination=8;settings.desktopStrength=1
    let nativeDisplay=CGRect(x:0,y:0,width:2304,height:1440)
    let nativeHole=CGRect(x:800,y:400,width:626.491,height:626.491/1.6)
    renderer.desktopRect=SIMD4(0,0,1,1)
    renderer.desktopViewport=DesktopCoordinates.rect(overlay:nativeHole,screen:nativeDisplay)
    let performance=try renderer.benchmark(width:Int(nativeDisplay.width*2),height:Int(nativeDisplay.height*2),frames:24)
    renderer.syntheticDesktop=nil
    let noFrame=try renderer.snapshot(to:output.appendingPathComponent("full-display-no-frame.png"),width:w,height:h)
    checks["missing_frame_clears_entire_background_surface"]=noFrame.allSatisfy{$0==0}
    checks["full_display_never_reads_live_capture"]=calls==0
    checks["background_cache_memory_bounded"]=renderer.desktopCacheSize.x<=DesktopField.maximumMapSide
    return (checks,["outside_local_support_changed_pixels":outsideChanged,"outside_support_samples":outsideSupportSamples,
        "inside_support_changed_pixels":insideChanged,"local_boundary_max_neighbor_deflection_change_px":maxBoundaryStep,"cropped_surface_max_channel_error":cropError,
        "schwarzschild_directional_relative_spread":symmetryError,"direct_kerr_reference_rays":rays.count,
        "max_cache_error_at_full_strength_px":maxRayError,"split_surface_max_channel_error":splitError,
        "main_disk_pixels":covered,"main_disk_outside_envelope_pixels":missed,"envelope_pixels":envelopePixels,"previous_circle_pixels":legacyPixels,"cache_side":renderer.desktopCacheSize.x,"local_background_performance":performance])
}
