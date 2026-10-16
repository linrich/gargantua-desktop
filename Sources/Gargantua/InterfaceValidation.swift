// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import ScreenCaptureKit

// Pure permission state tests: never asks macOS for access or starts capture.
func runInterfaceChecks(output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var granted = false, checksCalled = 0, requestsCalled = 0
    let permission = ScreenCapturePermission(preflight: { checksCalled += 1; return granted },
                                            request: { requestsCalled += 1; return false })
    var writes = [String]()
    let settings = Settings(persistent: false, preferenceWriter: { key, _ in writes.append(key) },
                            screenCapturePermission: permission)
    var checks = [String: Bool]()
    checks["startup_does_not_probe_or_request_capture"] = checksCalled == 0 && requestsCalled == 0 && !settings.desktopLensing
    settings.setDesktopLensing(false)
    checks["disabling_does_not_request_capture"] = checksCalled == 0 && requestsCalled == 0
    settings.setDesktopLensing(true)
    checks["denial_keeps_capture_off"] = !settings.desktopLensing && checksCalled == 1 && requestsCalled == 1
    checks["denial_exposes_recovery_action"] = settings.desktopPermissionNeedsAttention && settings.desktopStatus == ScreenCapturePermission.deniedMessage
    granted = true
    settings.setDesktopLensing(true)
    checks["explicit_retry_uses_current_permission"] = settings.desktopLensing && !settings.desktopPermissionNeedsAttention && checksCalled == 2
    checks["granted_permission_does_not_prompt_again"] = requestsCalled == 1
    settings.setDesktopLensing(false)
    checks["stop_clears_capture_state"] = !settings.desktopLensing && !settings.desktopPermissionNeedsAttention && settings.desktopStatus == "未采集桌面"
    checks["capture_switch_is_not_persisted"] = writes.isEmpty
    checks["new_settings_capture_stays_off"] = !Settings(persistent: false, screenCapturePermission: permission).desktopLensing
    var grantRequests = 0
    let newlyGranted = Settings(persistent: false, screenCapturePermission: ScreenCapturePermission(
        preflight: { false }, request: { grantRequests += 1; return true }))
    newlyGranted.setDesktopLensing(true)
    checks["new_grant_can_enter_capture_path"] = newlyGranted.desktopLensing && !newlyGranted.desktopPermissionNeedsAttention && grantRequests == 1
    checks["screen_capture_denial_is_identified"] = ScreenCapturePermission.isDenied(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
    checks["other_capture_errors_are_not_misreported_as_permission"] = !ScreenCapturePermission.isDenied(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue))
    checks["unrelated_error_code_is_not_permission"] = !ScreenCapturePermission.isDenied(NSError(domain: "GeneratedError", code: SCStreamError.Code.userDeclined.rawValue))
    let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "check_count": checks.count,
        "scope": "Injected permission decisions only; no OS permission request, capture, file drop, recycling or preference writes."]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("interface-state.json"))
    print("Interface state checks: \(checks.values.filter { $0 }.count)/\(checks.count)")
    guard checks.values.allSatisfy({ $0 }) else { throw RenderError.unavailable("界面状态检查失败。") }
}

// UI preview of the production View. Nonpersistent settings and forced denial
// make toggling the lens safe without reading desktop frames or requesting TCC.
final class InterfacePreviewDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings(persistent: false, screenCapturePermission: ScreenCapturePermission(preflight: { false }, request: { false }))
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = ControlPanel(settings: settings, center: {}, quit: { NSApp.terminate(nil) }, createTrashTestFile: {})
        let host = NSHostingView(rootView: ScrollView { panel })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 710), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Gargantua · v0.9.8 界面验证（不采集桌面）"
        window.contentView = host; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window; NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
