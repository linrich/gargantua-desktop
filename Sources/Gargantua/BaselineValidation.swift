// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal
import QuartzCore

private struct BaselineCase {
    let name: String
    let width: Int
    let height: Int
    let holeWidth: Int
    let background: Bool
    init(_ name: String) throws {
        self.name = name
        background = name.hasPrefix("desktop-")
        switch name {
        case "small": width=540; height=338; holeWidth=540
        case "retina", "transitions": width=720; height=450; holeWidth=720
        case "medium": width=1520; height=950; holeWidth=1520
        case "large": width=2400; height=1500; holeWidth=2400
        case "maximum", "wide-psf": width=3840; height=2400; holeWidth=3840
        case "measured-psf": width=531; height=333; holeWidth=531
        case "desktop-small": width=3840; height=2400; holeWidth=720
        case "desktop-medium": width=3840; height=2400; holeWidth=1520
        case "desktop-maximum": width=3840; height=2400; holeWidth=3840
        default: throw RenderError.unavailable("未知基线案例：\(name)")
        }
    }
    func settings() -> Settings {
        let s = Settings(persistent:false)
        s.restoreAppearance()
        s.quality = name == "small" ? .balanced : .cinematic
        s.size = name == "small" ? 360 : Double(holeWidth)/2
        s.displayedWidth = s.size
        s.desktopLensing = background
        if name == "wide-psf" { s.lensScale=2; s.glow=3 }
        if name == "measured-psf" {
            s.spin = -0.998; s.inclination=35; s.relativistic=true
            s.shutterAngle=360; s.setPalette(.blue)
            s.measuredPSF = MeasuredPSF(format:"linear-intensity-psf-v1",size:5,pitchAt800:1.7,
                values:[0,0,0.04,0,0, 0,0.02,0.05,0,0, 0.1,0.07,0.5,0.09,0, 0,0.03,0.06,0,0, 0,0,0.04,0,0])
            s.psfRevision += 1
        }
        return s
    }
    func configure(_ renderer: BlackHoleRenderer) throws {
        guard background else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:512,height:320,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture=renderer.device.makeTexture(descriptor:descriptor) else {throw RenderError.unavailable("无法创建生成背景。")}
        var pixels=[UInt8](repeating:255,count:512*320*4)
        for y in 0..<320 { for x in 0..<512 {
            let i=(y*512+x)*4
            pixels[i]=UInt8(x%256); pixels[i+1]=UInt8(y%256)
            pixels[i+2]=(x/23+y/19)%2 == 0 ? 220 : 30
        }}
        pixels.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,512,320),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:512*4)}
        renderer.syntheticDesktop=texture
        let scale=Float(holeWidth)/Float(width)
        renderer.desktopViewport=SIMD4((1-scale)/2,(1-scale)/2,scale,scale)
        // Fail if a future refactor tries to turn an offscreen run into capture.
        renderer.desktopFrameProvider={preconditionFailure("Baseline must not access live capture")}
    }
}

private func baselineStats(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["count":0] }
    let ordered=values.sorted()
    let middle=ordered.count/2
    let median=ordered.count%2 == 0 ? (ordered[middle-1]+ordered[middle])/2 : ordered[middle]
    return ["count":values.count,"median_ms":median,
            "p95_ms":ordered[max(0,Int(ceil(Double(ordered.count)*0.95))-1)],
            "min_ms":ordered[0],"max_ms":ordered.last!,"samples_ms":values]
}
private func countDelta(_ after: [String:Int], _ before: [String:Int]) -> [String:Int] {
    after.mapValues { $0 }.reduce(into:[:]) { $0[$1.key] = $1.value - (before[$1.key] ?? 0) }
}
private func finishBaseline(_ command: MTLCommandBuffer) throws {
    command.waitUntilCompleted()
    if let error=command.error {throw error}
    guard command.status == .completed else {throw RenderError.unavailable("基线 GPU 指令未完成。")}
}

// One worker per mode/case. The Python driver gives every worker a fresh
// process so OS lifetime memory high-water marks don't inherit earlier cases.
func runBaselineWorker(mode: String, name: String, output: URL) throws {
    guard ["timing","memory","quality","transitions"].contains(mode) else {throw RenderError.unavailable("未知基线模式。")}
    guard !FileManager.default.fileExists(atPath:output.path) else {throw RenderError.unavailable("基线输出已存在，拒绝覆盖。")}
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let specification=try BaselineCase(name)
    let settings=specification.settings()
    let initStart=CACurrentMediaTime()
    let renderer=try BlackHoleRenderer(settings:settings,backgroundOnly:specification.background)
    let initMS=(CACurrentMediaTime()-initStart)*1000
    try specification.configure(renderer)
    var report: [String:Any] = ["schema_version":1,"mode":mode,"case":name,
        "gpu":renderer.device.name,"os":ProcessInfo.processInfo.operatingSystemVersionString,
        "physical_memory_bytes":ProcessInfo.processInfo.physicalMemory,
        "renderer_initialization_ms":initMS,
        "scope":"Offscreen generated input only. No AppKit windows/drawables, live capture, WindowServer, display pacing, sustained power or UI-event latency. Renderer initialization excludes the app's second renderer and window/control construction.",
        "parameters":["width":specification.width,"height":specification.height,"hole_width":specification.holeWidth,
            "spin":settings.spin,"inclination":settings.inclination,"brightness":settings.brightness,
            "glow":settings.glow,"lens_scale":settings.lensScale,"lens_response":settings.lensResponse,
            "beam_filtering":settings.beamFiltering,"edge_grid":renderer.edgeGrid,
            "shutter_angle":settings.shutterAngle,"shutter_duration":settings.shutterDuration,
            "effective_speed":settings.effectiveSpeed,"target_fps":settings.targetFPS,
            "relativistic":settings.relativistic,"disk_hue":settings.diskHue,"disk_saturation":settings.diskSaturation,
            "desktop_strength":settings.desktopStrength,"measured_psf":settings.measuredPSF != nil],
        "thermal_state_start":ProcessInfo.processInfo.thermalState.rawValue]
    var checks=[String:Bool]()
    func frame(_ profile: FrameProfile?, width: Int? = nil, height: Int? = nil, time: Float = 12) throws -> [String:Any] {
        let before=renderer.baselineBuildCounts,start=CACurrentMediaTime()
        let (command,cpu)=try renderer.submitBaseline(width:width ?? specification.width,height:height ?? specification.height,time:time,profile:profile)
        let wait=CACurrentMediaTime()
        try finishBaseline(command)
        var record: [String:Any] = ["cpu_encode_ms":cpu,"post_commit_wait_ms":(CACurrentMediaTime()-wait)*1000,
            "frame_wall_ms":(CACurrentMediaTime()-start)*1000,
            "gpu_command_ms":(command.gpuEndTime-command.gpuStartTime)*1000,
            "preparation_gpu_ms":renderer.preparationGPUTimeMS,
            "preparation_wait_ms":renderer.preparationWaitMS,
            "total_gpu_commands_ms":renderer.preparationGPUTimeMS+(command.gpuEndTime-command.gpuStartTime)*1000,
            "build_delta":countDelta(renderer.baselineBuildCounts,before)]
        if let profile {record["profile"]=try profile.resolve()}
        return record
    }
    if mode == "timing" {
        report["cold_frame"]=try frame(FrameProfile(device:renderer.device))
        let coldCounts=renderer.baselineBuildCounts
        checks["cold_builds_expected"] = specification.background
            ? coldCounts == ["geometry":0,"material":0,"foreground_targets":0,"desktop_map":1,"psf_kernel":0,"fft_targets":0]
            : coldCounts == ["geometry":1,"material":1,"foreground_targets":1,"desktop_map":0,"psf_kernel":1,"fft_targets":1]
        for i in 0..<8 { _ = try autoreleasepool {try frame(i%2 == 0 ? nil : FrameProfile(device:renderer.device),time:12+Float(i)/60)} }
        let before=renderer.baselineBuildCounts
        var plain=[[String:Any]](),sampled=[[String:Any]]()
        // ABBA in each cycle, identical material time for all four frames.
        // 64 samples per path. No counters/memory polling on the plain path.
        for cycle in 0..<32 {
            for enabled in [false,true,true,false] {
                let value=try autoreleasepool {try frame(enabled ? FrameProfile(device:renderer.device) : nil,time:12+Float(cycle)/30)}
                if enabled {sampled.append(value)} else {plain.append(value)}
            }
        }
        func summarize(_ records: [[String:Any]]) -> [String:Any] {
            var value=[String:Any]()
            for key in ["gpu_command_ms","cpu_encode_ms","frame_wall_ms","post_commit_wait_ms"] {
                value[key]=baselineStats(records.compactMap {$0[key] as? Double})
            }
            for (source,destination) in [("gpu_stages_ms","gpu_stages"),("gpu_vertex_stages_ms","gpu_vertex_stages"),("cpu_encode_stages_ms","cpu_stages")] {
                var samples=[String:[Double]]()
                for r in records {if let p=r["profile"] as? [String:Any],let stages=p[source] as? [String:Double] {
                    for (key,time) in stages {samples[key,default:[]].append(time)}
                }}
                value[destination]=samples.mapValues {baselineStats($0)}
            }
            return value
        }
        let a=summarize(plain),b=summarize(sampled)
        report["steady_uninstrumented"]=a; report["steady_instrumented"]=b
        let aGPU=(a["gpu_command_ms"] as! [String:Any])["median_ms"] as! Double
        let bGPU=(b["gpu_command_ms"] as! [String:Any])["median_ms"] as! Double
        report["sampling_gpu_median_delta_percent"]=(bGPU/aGPU-1)*100
        report["steady_raw_uninstrumented"]=plain; report["steady_raw_instrumented"]=sampled
        report["steady_build_delta"]=countDelta(renderer.baselineBuildCounts,before)
        checks["steady_reuses_all_caches"]=renderer.baselineBuildCounts == before
        checks["finite_positive_gpu_times"]=(plain+sampled).allSatisfy {($0["gpu_command_ms"] as? Double).map {$0.isFinite && $0>0} == true}
        // Missing hardware support remains visible rather than fabricated as 0.
        checks["gpu_stage_counters_available"] = !(b["gpu_stages"] as! [String:Any]).isEmpty
    } else if mode == "memory" {
        report["memory_before_work"]=PeakMemory.process()
        let memory=PeakMemory(device:renderer.device);memory.start()
        let first=try frame(FrameProfile(device:renderer.device,counters:false,memory:memory))
        report["cold_build_delta"]=first["build_delta"]
        let before=renderer.baselineBuildCounts
        // Same queue/resources, up to two submitted frames, as in the live gate.
        var commands=[MTLCommandBuffer]()
        for i in 0..<2 {
            let (command,_)=try renderer.submitBaseline(width:specification.width,height:specification.height,time:12+Float(i)/60)
            commands.append(command);memory.checkpoint()
        }
        for command in commands {try finishBaseline(command)}
        report["memory"]=memory.stop()
        report["memory_after_work"]=PeakMemory.process()
        report["max_submitted_frames"]=2
        checks["warm_memory_frames_reuse_caches"]=renderer.baselineBuildCounts == before
    } else if mode == "quality" {
        let a=try renderer.snapshot(to:output.appendingPathComponent("normal.png"),width:specification.width,height:specification.height)
        // A fresh renderer exercises profiling on cold rebuilds as well.
        let other=try BlackHoleRenderer(settings:specification.settings(),backgroundOnly:specification.background)
        try specification.configure(other)
        let p=try FrameProfile(device:other.device)
        let b=try other.snapshot(to:output.appendingPathComponent("profiled-cold.png"),width:specification.width,height:specification.height,profile:p)
        let q=try FrameProfile(device:other.device)
        let c=try other.snapshot(to:output.appendingPathComponent("profiled-warm.png"),width:specification.width,height:specification.height,profile:q)
        report["cold_profile"]=try p.resolve();report["warm_profile"]=try q.resolve()
        checks["cold_profile_exact_rgba"]=a == b
        checks["warm_profile_exact_rgba"]=a == c
        report["max_rgba_byte_difference"]=zip(a,b).reduce(0) {max($0,abs(Int($1.0)-Int($1.1)))}
    } else {
        let memory=PeakMemory(device:renderer.device);memory.start()
        var events=[[String:Any]]()
        var w=720,h=450
        let names=["cold","unchanged","brightness","palette","speed","spin","inclination","glow","lens_scale","resize","resize_repeat","shrink"]
        for (i,event) in names.enumerated() {
            switch event {
            case "brightness": settings.brightness=2
            case "palette": settings.setPalette(.blue)
            case "speed": settings.speed=0.1
            case "spin": settings.spin=0.6
            case "inclination": settings.inclination=16
            case "glow": settings.glow=1.2
            case "lens_scale": settings.lensScale=2
            case "resize": w=1520;h=950;settings.displayedWidth=760
            case "shrink": w=720;h=450;settings.displayedWidth=360
            default: break
            }
            var result=try autoreleasepool {try frame(FrameProfile(device:renderer.device,memory:memory),width:w,height:h,time:12+Float(i)/30)}
            result["event"]=event;result["width"]=w;result["height"]=h
            result["resources"]=renderer.baselineResources
            let delta=result["build_delta"] as! [String:Int]
            let geometry=["cold","spin","inclination","resize","shrink"].contains(event) ? 1:0
            let material=["cold","spin","resize","shrink"].contains(event) ? 1:0
            let psf=["cold","glow","lens_scale","resize","shrink"].contains(event) ? 1:0
            let targets=["cold","resize","shrink"].contains(event) ? 1:0
            checks["\(event)_rebuilds"]=delta["geometry"]==geometry && delta["material"]==material && delta["psf_kernel"]==psf && delta["foreground_targets"]==targets && delta["desktop_map"]==0
            events.append(result)
        }
        // Resize across the largest material tier while two commands may still
        // retain old resources. Timing is a stress diagnostic, not paced UI.
        var commands=[MTLCommandBuffer]()
        for width in [2560,2562] {
            if commands.count==2 {try finishBaseline(commands.removeFirst())}
            let (command,_)=try renderer.submitBaseline(width:width,height:Int((Double(width)/1.6).rounded()),time:12)
            commands.append(command);memory.checkpoint()
        }
        for command in commands {try finishBaseline(command)}
        report["events"]=events;report["memory"]=memory.stop()
        report["resize_burst"]=["widths":[2560,2562],"max_submitted_frames":2,"note":"Synthetic unpaced resize burst, including 4096-to-8192 material tier transition; not live drag latency."]
    }
    report["resources_after_work"]=renderer.baselineResources
    report["build_counts"]=renderer.baselineBuildCounts
    checks["no_subbeam_overflow"]=renderer.baselineResources["subbeam_overflows"] as? Int == 0
    report["thermal_state_end"]=ProcessInfo.processInfo.thermalState.rawValue
    report["checks"]=checks
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("report.json"),options:.atomic)
    // Hardware timestamp unavailability doesn't invalidate CPU/memory results.
    let required=checks.filter {$0.key != "gpu_stage_counters_available"}
    guard required.values.allSatisfy({$0}) else {throw RenderError.unavailable("基线检查失败：\(name) / \(mode)")}
    print("基线完成：\(name) / \(mode)");fflush(stdout)
}
