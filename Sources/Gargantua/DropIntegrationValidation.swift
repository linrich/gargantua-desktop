// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func runDesktopDropChecks(output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let settings = Settings(persistent: false)
    settings.restoreAppearance(); settings.visible = false; settings.clickThrough = true
    let overlay = try OverlayController(settings: settings, restorePosition: false)
    defer { overlay.stopCapture(); overlay.window.orderOut(nil) }
    settings.onChange = { [weak overlay] changes in overlay?.apply(changes) }
    var checks = [String: Bool]()
    checks["production_test_exception_absent"] = overlay.dropCanvas.trashSession == nil
    checks["production_real_recycle_defaults_off"] = !settings.realTrashEnabled && !overlay.dropCanvas.realTrashEnabled
    overlay.createTrashTestFile()
    checks["production_fixture_creation_disabled"] = settings.trashTestFileURL == nil && !FileManager.default.fileExists(atPath: overlay.trashTestSession.root.path)
    settings.realTrashEnabled = true
    checks["setting_reaches_actual_canvas"] = overlay.dropCanvas.realTrashEnabled && !overlay.dropCanvas.receptionEnabled
    settings.dropPreviewEnabled = false
    checks["reception_off_disarms_actual_canvas"] = !settings.realTrashEnabled && !overlay.dropCanvas.realTrashEnabled
    settings.dropPreviewEnabled = true
    let panel = ControlPanel(settings: settings, center: {}, quit: {}, createTrashTestFile: {})
    checks["production_panel_hides_diagnostics"] = !panel.recycleDiagnostics
    checks["overlay_is_borderless_nonactivating"] = overlay.window.styleMask.contains(.nonactivatingPanel) && !overlay.window.styleMask.contains(.titled)
    checks["overlay_and_effect_are_transparent"] = !overlay.window.isOpaque && !overlay.dropCanvas.isOpaque && overlay.dropCanvas.background == nil
    checks["effect_is_child_of_live_metal_view"] = overlay.dropCanvas.superview === overlay.view
    checks["capture_remains_off"] = !settings.desktopLensing
    checks["hidden_overlay_rejects_drops"] = !overlay.dropCanvas.receptionEnabled
    checks["preview_reserves_native_drag_input"] = !overlay.window.ignoresMouseEvents && settings.clickThrough
    settings.dropPreviewEnabled = false
    checks["disabling_preview_restores_passthrough"] = overlay.window.ignoresMouseEvents && !overlay.dropCanvas.receptionEnabled
    settings.clickThrough = false
    settings.dropPreviewEnabled = true; settings.dropPreviewEnabled = false
    checks["disabled_passthrough_preference_preserved"] = !overlay.window.ignoresMouseEvents && !settings.clickThrough
    settings.dropPreviewEnabled = true; settings.reduceDropMotion = true
    checks["reduced_motion_reaches_effect"] = overlay.dropCanvas.reduceMotionOverride
    settings.reduceDropMotion = false
    settings.realTrashEnabled = true
    settings.setClickThrough(true)
    checks["direct_passthrough_action_is_available_during_reception"] = settings.effectiveClickThrough && overlay.window.ignoresMouseEvents
    checks["passthrough_disarms_reception_and_recycling"] = !settings.dropPreviewEnabled && !settings.realTrashEnabled && !overlay.dropCanvas.realTrashEnabled && !overlay.dropCanvas.receptionEnabled
    settings.dropPreviewEnabled = true
    checks["explicit_reception_restores_input_without_rearming_trash"] = !settings.effectiveClickThrough && !overlay.window.ignoresMouseEvents && !settings.realTrashEnabled
    settings.setClickThrough(true); settings.setClickThrough(false)
    checks["passthrough_off_keeps_recycling_disarmed"] = !overlay.window.ignoresMouseEvents && !settings.dropPreviewEnabled && !settings.realTrashEnabled
    var geometryRows = [[String: Any]]()
    for (spin, angle) in [(0.0,8.0),(0.6,8.0),(-0.998,2.0),(0.998,35.0),(0.0,25.0)] {
        let geometry = DropGeometry(spin: spin, inclination: angle)
        let map = try DiskHitMap.make(renderer: overlay.renderer, geometry: geometry)
        let count = map.cells.filter { $0 }.count
        let name = "geometry_\(spin)_\(angle)"
        // At 35 degrees the projected disk legitimately covers over half the
        // rectangle. Check a bounded silhouette, not an arbitrary area ratio.
        checks[name+"_nonempty_bounded"] = count > 100 && count < map.cells.count
            && !map.cells[0] && !map.cells[map.cells.count-1]
        checks[name+"_preserves_surface"] = map.cells.indices.allSatisfy { !map.surfaceCells[$0] || map.cells[$0] }
        checks[name+"_outside_rejected"] = !map.contains(CGPoint(x: 0, y: 0), in: CGRect(x: 0, y: 0, width: 640, height: 400))
        for width in [360.0,480,640,960,1440] {
            let rect = CGRect(x: 0, y: 0, width: width, height: width/1.6)
            checks[name+"_size_\(width)_inside"] = map.contains(map.samplePoint(in: rect), in: rect)
        }
        geometryRows.append(["spin":spin,"inclination":angle,"accepted_cells":count])
    }
    settings.size = 480
    checks["resize_updates_effect_frame"] = overlay.dropCanvas.bounds.size == overlay.view.bounds.size && overlay.dropCanvas.bounds.width == overlay.window.frame.width
    // The transparent compositor must leave an empty overlay entirely clear.
    let canvas = overlay.dropCanvas
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 300,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 480*4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    canvas.draw(canvas.bounds)
    NSGraphicsContext.restoreGraphicsState()
    checks["idle_effect_has_no_opaque_rectangle"] = (0..<(480*300)).allSatisfy { bitmap.bitmapData![$0*4+3] == 0 }
    let loader = DropGeometryLoader(renderer: overlay.renderer, geometry: DropGeometry(spin: 0, inclination: 8))
    var applied = [DropGeometry](), received: DiskHitMap?
    loader.onResult = { result in
        if case .success(let map) = result { received = map; applied.append(loader.applied) }
    }
    let last = DropGeometry(spin: -0.6, inclination: 25)
    _ = loader.update(DropGeometry(spin: 0.998, inclination: 35))
    _ = loader.update(last)
    let deadline = Date().addingTimeInterval(10)
    while received == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    checks["geometry_change_applies_latest_only"] = applied == [last] && loader.applied == last
    checks["unchanged_geometry_not_rebuilt"] = !loader.update(last)
    if let received {
        let expected = try DiskHitMap.make(renderer: overlay.renderer, geometry: last)
        checks["async_geometry_matches_current_projection"] = received.cells == expected.cells
    } else { checks["async_geometry_matches_current_projection"] = false }
    let report: [String: Any] = ["passed":checks.values.allSatisfy { $0 }, "checks":checks,
                               "check_count":checks.count, "geometry_cases":geometryRows,
                               "scope":"Actual overlay composition, input-mode restoration, projected hit maps and asynchronous map update. No desktop capture or real user files."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        .write(to: output.appendingPathComponent("desktop-integration-report.json"), options: .atomic)
    print("Desktop integration checks: \(checks.filter { $0.value }.count)/\(checks.count)")
    guard checks.values.allSatisfy({ $0 }) else { throw RenderError.unavailable("Desktop integration checks failed: \(checks.filter { !$0.value }.keys.sorted())") }
}
