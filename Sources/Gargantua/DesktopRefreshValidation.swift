// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal

// Only generated backgrounds. No DesktopCapture, screen enumeration or stored
// user preferences. The oracle always redraws, regardless of the refresh key.
func runDesktopRefreshChecks(output: URL) throws {
    let settings=Settings(persistent:false)
    settings.desktopLensing=true
    let renderer=try BlackHoleRenderer(settings:settings,backgroundOnly:true)
    let reference=try BlackHoleRenderer(settings:settings,backgroundOnly:true)
    func grid(_ phase: Int) throws -> MTLTexture {
        let w=512,h=320
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:w,height:h,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let texture=renderer.device.makeTexture(descriptor:d) else {throw RenderError.unavailable("刷新测试纹理分配失败。")}
        var pixels=[UInt8](repeating:255,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let i=(y*w+x)*4,bright=((x/23+y/19+phase)%2)==0
            pixels[i]=bright ? 220:30;pixels[i+1]=UInt8((x+phase*90)%256);pixels[i+2]=UInt8(y%256)
        }}
        pixels.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
        return texture
    }
    let first=try grid(0),second=try grid(1)
    renderer.desktopViewport=SIMD4(0.25,0.25,0.5,0.5)
    var state=DesktopRefreshState(),sequence:UInt64?,w=640,h=400
    var actual=[UInt8](),records=[[String:Any]](),checks=[String:Bool]()
    let events=["initial_empty","empty_repeat","first_frame","idle","move","move_idle",
                "strength","spin","inclination","new_frame","blank","blank_idle","restart",
                "show_again","resize","disable","disabled_idle","enable","foreground_color",
                "display_rect","surface_recreated","surface_idle"]
    let expectedDraws:Set<Int>=[0,2,4,6,7,8,9,10,12,13,14,15,17,19,20]
    for (i,event) in events.enumerated() {
        switch i {
        case 2: sequence=1;renderer.syntheticDesktop=first
        case 4: renderer.desktopViewport.x += 0.08
        case 6: settings.desktopStrength=0.3
        case 7: settings.spin=0.6
        case 8: settings.inclination=16
        case 9: sequence=2;renderer.syntheticDesktop=second
        case 10: sequence=nil;renderer.syntheticDesktop=nil
        case 12: sequence=3;renderer.syntheticDesktop=first
        case 13,20: state.invalidate()
        case 14: w=800;h=500
        case 15: settings.desktopLensing=false
        case 17: settings.desktopLensing=true
        case 18: settings.brightness=5;settings.setPalette(.blue)
        case 19: renderer.desktopRect=SIMD4(0.1,0,0.9,1)
        default: break
        }
        reference.desktopRect=renderer.desktopRect;reference.desktopViewport=renderer.desktopViewport
        reference.syntheticDesktop=renderer.syntheticDesktop
        let key=renderer.desktopRefreshKey(sequence:sequence,size:SIMD2(w,h))
        let draw=state.needsDraw(key)
        if draw {
            actual=try renderer.snapshot(to:output.appendingPathComponent("refresh-actual.png"),width:w,height:h,reuseTarget:true)
            state.didSubmit(key)
        }
        let expected=try reference.snapshot(to:output.appendingPathComponent("refresh-reference.png"),width:w,height:h,reuseTarget:true)
        let difference=zip(actual,expected).map {abs(Int($0)-Int($1))}.max() ?? 0
        checks["\(event)_pixels"]=actual.count==expected.count && difference==0
        checks["\(event)_submission"]=draw==expectedDraws.contains(i)
        records.append(["event":event,"draw":draw,"max_byte_difference":difference])
    }
    var failed=DesktopRefreshState()
    let key=renderer.desktopRefreshKey(sequence:4,size:SIMD2(w,h))
    // A missed drawable/failed encoder must remain retryable; a successful
    // submission may be reused, and surface recreation must redraw it.
    checks["failed_submission_retries"]=failed.needsDraw(key) && failed.needsDraw(key)
    failed.didSubmit(key);checks["successful_submission_reused"] = !failed.needsDraw(key)
    failed.invalidate();checks["invalidated_submission_retries"]=failed.needsDraw(key)
    checks["no_foreground_geometry_allocated"]=renderer.geometryBuildCount==0 && renderer.materialBuildCount==0
    try JSONSerialization.data(withJSONObject:["checks":checks,"events":records,
        "note":"Synthetic retained-output comparison with an always-rendered oracle. Does not test WindowServer timing or real desktop capture."],options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("desktop-refresh-equivalence.json"),options:.atomic)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("背景刷新对照失败。")}
    print("背景刷新画面对照通过：\(checks.count) 项，所有通道差为 0。");fflush(stdout)

    settings.restoreAppearance();settings.desktopLensing=true;settings.spin=0.6
    renderer.syntheticDesktop=first;renderer.desktopRect=SIMD4(0,0,1,1)
    var timings=[[String:Any]]()
    // Fixed 3840x2400 background surface; 2x backing for 360/760 pt overlays,
    // plus a full-width overlay. 120 synthetic 30 Hz ticks = 4 s of input,
    // replayed without sleeping. These are NOT live frame-rate measurements.
    for holeWidth in [720,1520,3840] {
        let scale=Float(holeWidth)/3840
        renderer.desktopViewport=SIMD4((1-scale)/2,(1-scale)/2,scale,scale)
        for (name,period,moving) in [("static",120,false),("10_hz_updates",3,false),("30_hz_updates",1,false),("drag",120,true)] {
            var runs=[[String:Any]]()
            for optimized in [false,true,true,false] {
                let result=try renderer.benchmarkDesktopRefresh(width:3840,height:2400,ticks:120,newFrameEvery:period,moving:moving,optimized:optimized)
                let expected=optimized && !moving ? (119/period+1):120
                guard result["submitted"] as? Int == expected else {throw RenderError.unavailable("背景刷新提交次数不正确。")}
                runs.append(["optimized":optimized,"result":result])
            }
            timings.append(["hole_width_px":holeWidth,"scenario":name,"runs":runs])
            print("背景提交测量完成：\(holeWidth) px / \(name)");fflush(stdout)
        }
    }
    try JSONSerialization.data(withJSONObject:["gpu":renderer.device.name,"results":timings,
        "method":"ABBA, two warm-up frames per run, 120 synthetic ticks; baseline always submits, optimized shares the production refresh key/state. GPU command durations measured on a generated texture and a fixed 3840x2400 target. Excludes live capture, MTKView timers/drawables, foreground, WindowServer, initial mapping, sustained power and thermals. No claim of measured app FPS or energy savings."],options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("desktop-refresh-performance.json"),options:.atomic)
    var interleaved=[[String:Any]]()
    for holeWidth in [720,1520,3840] {
        let scale=Float(holeWidth)/3840
        renderer.desktopViewport=SIMD4((1-scale)/2,(1-scale)/2,scale,scale)
        for moving in [false,true] {
            let result=try renderer.compareChangingDesktop(width:3840,height:2400,moving:moving)
            interleaved.append(["hole_width_px":holeWidth,"moving":moving,"result":result])
        }
    }
    try JSONSerialization.data(withJSONObject:["gpu":renderer.device.name,"results":interleaved,
        "method":"Per-frame ABBA, 40 warm-up submissions and 300 measured frames per path; changing generated input. Follow-up to whole-run timing drift, not a live FPS/power test. Both paths submit every update."],options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("desktop-refresh-interleaved.json"),options:.atomic)
}
