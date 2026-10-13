// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Uses a separate temporary lease; never claims the live App's singleton lock
// and never enumerates or captures desktop content.
func runInstanceChecks(directory: String) throws {
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("gargantua-test-\(UUID().uuidString).lock")
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    func probe() throws -> Int32 {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--instance-lock-probe", lockURL.path]
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }
    var lease: InstanceLease? = try InstanceLease(url: lockURL)
    var checks = ["first_owner_acquires": lease?.acquired == true]
    checks["second_process_cannot_acquire"] = try probe() == 2
    withExtendedLifetime(lease) {}
    lease = nil
    checks["release_allows_next_process"] = try probe() == 0
    // The probe exits without Swift deinitialization; the kernel releases its
    // descriptor, including after a process exits unexpectedly.
    checks["process_exit_does_not_leave_stale_lock"] = try probe() == 0
    // Generated window metadata: a black control window is above a white
    // unrelated window. Whole-app exclusion incorrectly reveals the white one.
    let windows=[
        CaptureWindow(id:10,processID:100,bundleID:nil,title:nil),
        CaptureWindow(id:13,processID:100,bundleID:nil,title:nil),
        CaptureWindow(id:32,processID:101,bundleID:AppInstance.bundleIdentifier,title:DesktopCapturePolicy.backgroundTitle),
        CaptureWindow(id:11,processID:100,bundleID:AppInstance.bundleIdentifier,title:"Gargantua · 控制台"),
        CaptureWindow(id:20,processID:200,bundleID:"com.example.background",title:"White window"),
        CaptureWindow(id:30,processID:101,bundleID:AppInstance.bundleIdentifier,title:"Gargantua"),
        CaptureWindow(id:31,processID:101,bundleID:AppInstance.bundleIdentifier,title:"Gargantua · 控制台"),
        CaptureWindow(id:40,processID:200,bundleID:"com.example.background",title:"Gargantua"),
        CaptureWindow(id:12,processID:100,bundleID:AppInstance.bundleIdentifier,title:"Gargantua")
    ]
    let excluded=try DesktopCapturePolicy.excludedWindowIDs(in:windows,overlayIDs:[10,13],currentPID:100)
    checks["capture_excludes_exact_overlay_without_title_or_bundle"]=excluded.contains(10)
    checks["capture_preserves_control_window"] = !excluded.contains(11)
    checks["capture_preserves_same_pid_and_title_other_window"] = !excluded.contains(12)
    checks["capture_excludes_legacy_duplicate_overlay"]=excluded.contains(30)
    checks["capture_preserves_duplicate_control"] = !excluded.contains(31)
    checks["capture_preserves_other_apps_even_with_same_title"] = !excluded.contains(20) && !excluded.contains(40)
    checks["capture_exclusion_is_limited_to_overlays"]=excluded == [10,13,30,32]
    checks["capture_excludes_background_surface"]=excluded.contains(13) && excluded.contains(32)
    // Simulate front-to-back compositing at a point covered by both windows.
    let layers:[UInt32]=[10,11,20]
    checks["control_occludes_underlying_white_window"]=layers.first(where:{!excluded.contains($0)})==11
    checks["fixture_detects_previous_whole_app_exclusion"]=layers.first(where:{$0 != 10 && $0 != 11})==20
    for (name,id,pid) in [("zero_id",UInt32(0),Int32(100)),("missing_id",UInt32(99),Int32(100)),("wrong_owner",UInt32(20),Int32(100))] {
        do {
            _ = try DesktopCapturePolicy.excludedWindowIDs(in:windows,overlayIDs:[10,id],currentPID:pid)
            checks["capture_rejects_\(name)"]=false
        } catch {checks["capture_rejects_\(name)"]=true}
    }
    let data = try JSONSerialization.data(withJSONObject: ["checks": checks], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("single-instance.json"), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
    guard checks.values.allSatisfy({ $0 }) else { throw RenderError.unavailable("单实例检查未全部通过。") }
}
