// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal
import QuartzCore

// Generated-input diagnostics only: no windows, capture, preference writes or network.
func runResourceOptimizationChecks(mode: String, output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw RenderError.unavailable("资源验证输出已存在，拒绝覆盖。")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var report: [String: Any] = ["mode": mode, "thermal_state_start":ProcessInfo.processInfo.thermalState.rawValue]
    var checks = [String: Bool]()
    if mode.hasPrefix("startup-") {
        let shared = mode == "startup-shared"
        guard shared || mode == "startup-separate" else { throw RenderError.unavailable("未知启动对照模式。") }
        let settings = Settings(persistent: false)
        let start = CACurrentMediaTime()
        let foreground = try BlackHoleRenderer(settings: settings)
        let middle = CACurrentMediaTime()
        let background = try BlackHoleRenderer(settings: settings, backgroundOnly: true,
                                              resources: shared ? foreground.resources : nil)
        let end = CACurrentMediaTime()
        checks["sharing_matches_requested_mode"] = (foreground.resources === background.resources) == shared
        checks["mutable_lens_is_separate"] = foreground.lens !== background.lens
        checks["no_foreground_textures_at_initialization"] = (foreground.baselineResources["resource_sum_bytes"] as? Int) == 0
        checks["no_background_textures_at_initialization"] = (background.baselineResources["resource_sum_bytes"] as? Int) == 0
        report["foreground_ms"] = (middle-start)*1000
        report["background_ms"] = (end-middle)*1000
        report["total_ms"] = (end-start)*1000
        report["library_builds"] = shared ? 1 : 2
        report["pipeline_builds"] = foreground.resources.pipelineCount*(shared ? 1 : 2)
        report["memory"] = PeakMemory.process()
        report["scope"] = "Same-binary shared versus separate immutable resources; two renderer constructors only, excludes windows and first frame. Each invocation must be a fresh process."
        withExtendedLifetime((foreground, background)) {}
    } else if mode == "checks" {
        var writes = [(String, Any)](), changes = [SettingsChange]()
        let settings = Settings(persistent: false, preferenceWriter: { writes.append(($0, $1)) })
        settings.restoreAppearance(); writes.removeAll()
        settings.onChange = { changes.append($0) }
        settings.brightness = 2
        checks["brightness_one_key_one_appearance_update"] = writes.map(\.0) == ["brightness"] && changes == [.appearance]
        writes.removeAll(); changes.removeAll()
        settings.brightness = 2
        checks["unchanged_value_has_no_effect"] = writes.isEmpty && changes.isEmpty
        settings.setPalette(.blue)
        checks["palette_batches_two_keys_one_update"] = Set(writes.map(\.0)) == ["diskHue", "diskSaturation"] && changes == [.appearance]
        writes.removeAll(); changes.removeAll()
        settings.paused = true
        checks["pause_updates_playback_without_capture_or_layout"] = writes.isEmpty && changes == [[.playback, .appearance]]
        changes.removeAll(); settings.visible = false
        checks["visibility_routes_windows_playback_capture"] = writes.isEmpty && changes == [[.window, .playback, .desktop, .appearance]]
        changes.removeAll(); settings.desktopLensing = true
        checks["capture_opt_in_routes_resolution_and_timing"] = writes.isEmpty && changes == [[.layout, .playback, .desktop, .appearance]]
        settings.desktopLensing = false; settings.visible = true; settings.paused = false
        changes.removeAll(); settings.desktopStrength = 0.3
        checks["strength_does_not_resize"] = changes == [[.desktop, .appearance]]
        changes.removeAll(); settings.spin = 0.6
        checks["spin_updates_appearance_and_desktop"] = changes == [[.appearance, .desktop]]
        settings.size = 1000; settings.quality = .cinematic; settings.speed = 0.2
        writes.removeAll(); changes.removeAll(); settings.restoreAppearance()
        checks["restore_batches_and_preserves_defaults"] = changes.count == 1 && settings.size == OverlaySizing.minimum && settings.quality == .balanced && settings.spin == 0 && settings.brightness == 1.3 && settings.speed == MotionTuning.defaultSpeed && settings.selectedPalette == .gold
        checks["restore_writes_each_changed_key_once"] = Set(writes.map(\.0)).count == writes.count
        writes.removeAll(); changes.removeAll()
        settings.batchUpdates { settings.brightness = 2; settings.batchUpdates { settings.brightness = 3; settings.glow = 1 } }
        checks["nested_batch_persists_final_values_once"] = writes.count == 2 && writes.first(where: {$0.0 == "brightness"})?.1 as? Double == 3 && changes == [.appearance]
        writes.removeAll(); changes.removeAll(); settings.clickThrough.toggle()
        checks["mouse_passthrough_only_updates_window"] = writes.map(\.0) == ["clickThrough"] && changes == [.window]
        writes.removeAll(); changes.removeAll(); settings.alwaysOnTop.toggle()
        checks["window_level_updates_background_order"] = writes.map(\.0) == ["alwaysOnTop"] && changes == [[.window, .desktop]]
        settings.onChange = nil
        settings.restoreAppearance()
        let reference = try BlackHoleRenderer(settings: settings)
        reference.useDemandBeamAllocation = false
        let optimized = try BlackHoleRenderer(settings: settings, resources: reference.resources)
        var events = [[String: Any]]()
        let cases: [(String, Int, Int, Double, Double, Int)] = [
            ("initial",720,450,0,8,4), ("warm",720,450,0,8,4),
            ("spin",720,450,0.998,8,4), ("inclination",720,450,-0.998,35,4),
            ("resize",1520,950,0,8,4), ("shrink",360,225,0,8,4),
            ("dense-oracle",160,100,0.6,8,8), ("restore-grid",360,225,0,8,4)]
        for (name,w,h,spin,angle,grid) in cases {
            try autoreleasepool {
                settings.spin = spin; settings.inclination = angle
                reference.edgeGrid = grid; optimized.edgeGrid = grid
                let a = try reference.snapshot(to: output.appendingPathComponent(name+"-reserve.png"),width:w,height:h)
                let b = try optimized.snapshot(to: output.appendingPathComponent(name+"-demand.png"),width:w,height:h)
                let linearA = try reference.scenePixels(), linearB = try optimized.scenePixels()
                let ra = reference.baselineResources, rb = optimized.baselineResources
                let used = rb["subbeams_used"] as! Int, capacity = rb["subbeam_capacity"] as! Int
                checks[name+"_rgba_exact"] = a == b
                checks[name+"_linear_scene_exact"] = linearA == linearB
                checks[name+"_same_subbeams"] = ra["subbeams_used"] as? Int == used
                checks[name+"_zero_overflows"] = ra["subbeam_overflows"] as? Int == 0 && rb["subbeam_overflows"] as? Int == 0
                checks[name+"_capacity_covers_demand"] = capacity >= used && capacity-used < 4096
                if name == "warm" { checks["warm_no_rendezvous"] = optimized.preparationGPUTimeMS == 0 && optimized.beamAllocationCount == 1 }
                events.append(["name":name,"reserve":ra,"demand":rb,"builds":optimized.baselineBuildCounts])
            }
        }
        // A second renderer shares pipeline objects but cannot mutate the first
        // renderer's material/geometry/PSF keys or pixels.
        let before = optimized.baselineBuildCounts
        let stable = try optimized.snapshot(to: output.appendingPathComponent("isolation-before.png"),width:360,height:225)
        let otherSettings = Settings(persistent:false); otherSettings.restoreAppearance(); otherSettings.spin = 0.9
        let other = try BlackHoleRenderer(settings:otherSettings,resources:optimized.resources)
        _ = try other.snapshot(to: output.appendingPathComponent("isolation-other.png"),width:540,height:338)
        let stableAfter = try optimized.snapshot(to: output.appendingPathComponent("isolation-after.png"),width:360,height:225)
        checks["shared_resources_do_not_share_mutable_caches"] = stable == stableAfter && optimized.baselineBuildCounts == before && optimized.lens !== other.lens
        for (name,value) in try optimized.checkAsyncBeamPreparation(output:output) { checks[name] = value }
        report["events"] = events
    } else { throw RenderError.unavailable("未知资源验证模式。") }
    report["thermal_state_end"] = ProcessInfo.processInfo.thermalState.rawValue
    report["checks"] = checks
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("report.json"))
    guard checks.values.allSatisfy({$0}) else { throw RenderError.unavailable("资源验证未通过：\(checks.filter {!$0.value}.keys.sorted())") }
    print("资源验证完成：\(mode)，\(checks.count) 项。")
}
