// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings()
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var controls: NSWindow?
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppInstance.reopenNotification,
            object: String(ProcessInfo.processInfo.processIdentifier), queue: .main) { [weak self] _ in
                self?.showControls()
            }
        do {
            overlay = try OverlayController(settings: settings)
            overlay?.onOpenControls = { [weak self] in self?.showControls() }
            settings.onChange = { [weak self] changes in self?.overlay?.apply(changes) }
            setupStatusItem()
            showControls()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Gargantua 无法启动"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "退出")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal(); NSApp.terminate(nil)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 10, height: 10))
            ring.lineWidth = 1.4; ring.stroke()
            let disk = NSBezierPath(ovalIn: NSRect(x: 1, y: 8, width: 18, height: 4))
            disk.lineWidth = 1.2; disk.stroke()
            return true
        }
        image.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Gargantua · 卡冈图雅"
        item.button?.setAccessibilityLabel("Gargantua 黑洞控制")
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu; statusItem = item
        updateMenu(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu(menu) }

    private func updateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, key: String = "", checked: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        let title = NSMenuItem(title: "GARGANTUA · 卡冈图雅", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        add("打开控制面板…", #selector(showControls), key: ",")
        menu.addItem(.separator())
        add(settings.visible ? "隐藏黑洞" : "显示黑洞", #selector(toggleVisibility), key: "h")
        add(settings.paused ? "继续流动" : "暂停时间", #selector(togglePause), key: "p")
        add("鼠标穿透", #selector(toggleClickThrough), checked: settings.clickThrough)
        add("始终置顶", #selector(toggleTop), checked: settings.alwaysOnTop)
        add("回到屏幕中央", #selector(centerOverlay))
        menu.addItem(.separator())
        add("退出 Gargantua", #selector(quit), key: "q")
    }

    @objc func showControls() {
        if controls == nil {
            let content = ControlPanel(settings: settings,
                center: { [weak self] in self?.overlay?.center() },
                quit: { NSApp.terminate(nil) })
            let hosting = NSHostingView(rootView: ScrollView { content }.background(Color(red: 0.045, green: 0.05, blue: 0.064)))
            let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 60
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: min(710, maxHeight)),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Gargantua · 控制台"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.095, green: 0.096, blue: 0.112, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = hosting
            window.center()
            controls = window
        }
        NSApp.activate(ignoringOtherApps: true)
        controls?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleVisibility() { settings.visible.toggle() }
    @objc private func togglePause() { settings.paused.toggle() }
    @objc private func toggleClickThrough() { settings.clickThrough.toggle() }
    @objc private func toggleTop() { settings.alwaysOnTop.toggle() }
    @objc private func centerOverlay() { overlay?.center() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stopCapture()
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
    }
}

func runRenderChecks(directory: String) throws {
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let settings = Settings(persistent: false)
    settings.restoreAppearance()
    let renderer = try BlackHoleRenderer(settings: settings)
    try runDefaultsChecks(renderer:renderer,output:output)
    try runMotionChecks(renderer:renderer,output:output)
    try runKerrChecks(renderer: renderer, output: output)
    try runBundleChecks(renderer: renderer, output: output)
    let width = 1280, height = 800
    let start = CACurrentMediaTime()
    let first = try renderer.snapshot(to: output.appendingPathComponent("gargantua-transparent.png"))
    let defaultDiagnostics = try renderer.geometryDiagnostics()
    let defaultDark = try renderer.snapshot(to: output.appendingPathComponent("gargantua-dark.png"), background: 1)
    _ = try renderer.snapshot(to: output.appendingPathComponent("gargantua-light.png"), background: 2)
    let second = try renderer.snapshot(to: output.appendingPathComponent("gargantua-motion.png"), time: 14)
    let duplicate = try renderer.snapshot(to: output.appendingPathComponent("gargantua-repeat.png"))
    settings.inclination = 25
    let inclined = try renderer.snapshot(to: output.appendingPathComponent("gargantua-inclined.png"))
    settings.inclination = 8
    settings.relativistic = true
    let physical = try renderer.snapshot(to: output.appendingPathComponent("gargantua-relativistic.png"), background: 1)
    settings.spin = 0.998
    let extreme = try renderer.snapshot(to: output.appendingPathComponent("gargantua-extreme-spin.png"), background: 1)
    let extremeDiagnostics = try renderer.geometryDiagnostics()
    var boundaryDiagnostics: [[String: Any]] = []
    for spin in [-0.998,0.998] {
        for angle in [2.0,35.0] {
            settings.spin = spin; settings.inclination = angle
            _ = try renderer.snapshot(to: output.appendingPathComponent("boundary-\(spin)-\(angle).png"), width: 640, height: 400)
            var diagnostic = try renderer.geometryDiagnostics()
            diagnostic["spin"] = spin; diagnostic["elevation"] = angle
            boundaryDiagnostics.append(diagnostic)
        }
    }
    func pixel(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
    let corners = [pixel(0,0), pixel(width-1,0), pixel(0,height-1), pixel(width-1,height-1)]
    var lit = 0, changed = 0, changedAngle = 0, badPremultiplication = 0
    var darkShadow = 0, shiftedPixels = 0, spinPixels = 0
    for i in stride(from: 0, to: first.count, by: 4) {
        if first[i] > 35 { lit += 1 }
        if abs(Int(first[i]) - Int(second[i])) > 3 { changed += 1 }
        if abs(Int(first[i]) - Int(inclined[i])) > 3 { changedAngle += 1 }
        if first[i] > first[i+3] || first[i+1] > first[i+3] || first[i+2] > first[i+3] { badPremultiplication += 1 }
        let x = (i/4)%width, y = (i/4)/width
        if x > width*3/10 && x < width*7/10 && y > height/4 && y < height*3/4 && first[i+3] == 255 && first[i] < 25 { darkShadow += 1 }
        if abs(Int(defaultDark[i])-Int(physical[i])) > 5 { shiftedPixels += 1 }
        if abs(Int(physical[i])-Int(extreme[i])) > 5 { spinPixels += 1 }
    }
    let checks: [String: Bool] = [
        "transparent_corners": corners.allSatisfy { first[$0+3] == 0 },
        "opaque_dark_shadow_region": darkShadow > 1_000,
        "frequency_transfer_changes_image": shiftedPixels > 1_000,
        "spin_changes_image": spinPixels > 5_000,
        "visible_disk": lit > 10_000 && lit < width * height / 2,
        "animation_changes_pixels": changed > 1_000,
        "inclination_changes_geometry": changedAngle > 5_000,
        "deterministic_frame": first == duplicate,
        "valid_premultiplied_alpha": badPremultiplication == 0
    ]
    settings.restoreAppearance()
    settings.lensResponse = false
    let noLens = try renderer.snapshot(to:output.appendingPathComponent("gargantua-no-lens.png"),background:1)
    settings.lensResponse = true; settings.beamFiltering = false
    let noBeams = try renderer.snapshot(to:output.appendingPathComponent("gargantua-no-beams.png"),background:1)
    settings.beamFiltering = true; settings.shutterAngle = 0; settings.speed = 2
    let noShutter = try renderer.snapshot(to:output.appendingPathComponent("gargantua-shutter-0.png"),background:1)
    settings.shutterAngle = 360
    let fullShutter = try renderer.snapshot(to:output.appendingPathComponent("gargantua-shutter-360.png"),background:1)
    func changedPixels(_ a:[UInt8],_ b:[UInt8])->Int {stride(from:0,to:a.count,by:4).filter {abs(Int(a[$0])-Int(b[$0]))>=1}.count}
    let controls=["lens_changed_pixels":changedPixels(defaultDark,noLens),"beam_changed_pixels":changedPixels(defaultDark,noBeams),
                  "shutter_changed_pixels":changedPixels(noShutter,fullShutter)]
    try JSONSerialization.data(withJSONObject:controls,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("optics-controls.json"),options:.atomic)
    guard controls.values.allSatisfy({$0>100}) else {throw RenderError.unavailable("光学控件未产生预期的图像变化。")}
    settings.restoreAppearance()
    try runAppearanceChecks(renderer:renderer,output:output)
    try runMaterialChecks(renderer:renderer,output:output)
    try runDetailChecks(renderer:renderer,output:output)
    try runDesktopChecks(renderer:renderer,output:output)
    let performance=try runPerformanceComparison(renderer:renderer,output:output)
    try runEdgeChecks(renderer:renderer,output:output)
    let largest = try renderer.geometryDiagnostics()
    guard (largest["nonfinite"] as? Int) == 0, (largest["budget_exhausted"] as? Int) == 0,
          (largest["invalid_bundle_derivatives"] as? Int) == 0, (largest["refined_invalid"] as? Int) == 0,
          (largest["refinement_overflow"] as? Int) == 0 else {throw RenderError.unavailable("最大分辨率光束检查失败。")}
    try JSONSerialization.data(withJSONObject:largest,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("maximum-resolution.json"),options:.atomic)
    try JSONSerialization.data(withJSONObject:performance,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("performance.json"),options:.atomic)
    let result: [String: Any] = ["gpu": renderer.device.name, "width": width, "height": height,
        "elapsed_seconds": CACurrentMediaTime() - start, "checks": checks,
        "default_geometry": defaultDiagnostics, "default_spin":0.0,"default_size_pt":360,"extreme_spin_geometry": extremeDiagnostics,
        "parameter_boundaries": boundaryDiagnostics,
        "frequency_shifted_pixels": shiftedPixels, "spin_changed_pixels": spinPixels, "dark_shadow_pixels": darkShadow,
        "lit_pixels": lit, "animated_pixels": changed, "angle_changed_pixels": changedAngle,
        "note": "Offscreen GPU checks only. Window interaction, Spaces and sustained frame rate need native UI verification."]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("render-checks.json"), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
    guard checks.values.allSatisfy({ $0 }) else { throw RenderError.unavailable("渲染检查未全部通过。") }
    guard (defaultDiagnostics["nonfinite"] as? Int) == 0,
          (extremeDiagnostics["nonfinite"] as? Int) == 0,
          (defaultDiagnostics["budget_exhausted"] as? Int) == 0,
          (extremeDiagnostics["budget_exhausted"] as? Int) == 0 else {
        throw RenderError.unavailable("完整画面中存在未收敛的测地线，详见 render-checks.json。")
    }
    for diagnostic in [defaultDiagnostics,extremeDiagnostics] + boundaryDiagnostics {
        guard (diagnostic["nonfinite"] as? Int) == 0, (diagnostic["budget_exhausted"] as? Int) == 0,
              let radial = diagnostic["max_radial_invariant_error"] as? Float,
              let polar = diagnostic["max_polar_invariant_error"] as? Float,
              radial < 0.002, polar < 0.002,
              (diagnostic["invalid_bundle_derivatives"] as? Int) == 0,
              (diagnostic["refinement_overflow"] as? Int) == 0,
              (diagnostic["refined_invalid"] as? Int) == 0 else {
            throw RenderError.unavailable("参数边界的测地线检查未通过，详见 render-checks.json。")
        }
    }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--instance-lock-probe" {
    do {
        let lease = try InstanceLease(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        withExtendedLifetime(lease) { exit(lease.acquired ? 0 : 2) }
    } catch { exit(1) }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--instance-test" {
    do { try runInstanceChecks(directory: CommandLine.arguments[2]) }
    catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--refresh-test" {
    do {
        let output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try runDesktopRefreshChecks(output:output)
        print("背景刷新优化检查通过（仅生成背景）。")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)
    }
} else if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--baseline-worker" {
    do {
        try runBaselineWorker(mode:CommandLine.arguments[2],name:CommandLine.arguments[3],
            output:URL(fileURLWithPath:CommandLine.arguments[4],isDirectory:true))
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)
    }
} else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--resource-test" {
    do { try runResourceOptimizationChecks(mode:CommandLine.arguments[2], output:URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)) }
    catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)
    }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--fft-tuning" {
    do {try runFFTTuning(output:URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true))}
    catch {FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)}
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--event-test" {
    do {try runDesktopEventChecks(output:URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true))}
    catch {FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)}
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--sampling-test" {
    do { try runSamplingOptimizationChecks(output:URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)) }
    catch {FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)}
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--psf-test" {
    do { try runPSFOptimizationChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)) }
    catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1)
    }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--performance-test" {
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = try BlackHoleRenderer(settings: Settings(persistent: false))
        try runFusedLensChecks(renderer: renderer, output: output)
        print("性能优化检查通过（仅生成画面）。")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--desktop-test" {
    do {
        let output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let renderer=try BlackHoleRenderer(settings:Settings(persistent:false))
        try runDesktopChecks(renderer:renderer,output:output)
        print("桌面引力透镜检查通过（仅生成背景）。")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
} else if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--self-test" {
    do { try runRenderChecks(directory: CommandLine.arguments[2]) }
    catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    do {
        if let lease = try AppInstance.acquire() {
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime((lease, delegate)) { app.run() }
        }
    } catch {
        let alert = NSAlert()
        alert.messageText = "Gargantua 无法启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "退出")
        alert.runModal()
    }
}
