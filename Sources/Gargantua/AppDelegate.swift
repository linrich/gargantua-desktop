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
    private let recycleDiagnostics: Bool

    init(recycleDiagnostics: Bool = false) {
        self.recycleDiagnostics = recycleDiagnostics
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppInstance.reopenNotification,
            object: String(ProcessInfo.processInfo.processIdentifier), queue: .main) { [weak self] _ in
                self?.showControls()
            }
        do {
            overlay = try OverlayController(settings: settings, recycleDiagnostics: recycleDiagnostics)
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
        add("鼠标穿透", #selector(toggleClickThrough), checked: settings.effectiveClickThrough)
        add(settings.realTrashEnabled ? "拖放吞入（真实回收已开启）" : "拖放吞入（普通文件只演示）", #selector(toggleDropPreview), checked: settings.dropPreviewEnabled)
        add("始终置顶", #selector(toggleTop), checked: settings.alwaysOnTop)
        add("回到屏幕中央", #selector(centerOverlay))
        menu.addItem(.separator())
        add("退出 Gargantua", #selector(quit), key: "q")
    }

    @objc func showControls() {
        if controls == nil {
            let content = ControlPanel(settings: settings,
                center: { [weak self] in self?.overlay?.center() },
                quit: { NSApp.terminate(nil) },
                createTrashTestFile: { [weak self] in self?.overlay?.createTrashTestFile() },
                recycleDiagnostics: recycleDiagnostics)
            let hosting = NSHostingView(rootView: ScrollView { content }.background(Color(red: 0.045, green: 0.05, blue: 0.064)))
            let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 60
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: min(710, maxHeight)),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Gargantua · 控制台"
            if Bundle.main.bundleIdentifier?.hasPrefix("local.gargantua.desktop-drop.") == true {
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                window.title = "Gargantua · 回收候选 v\(version) · \(build)"
            }
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
    @objc private func toggleClickThrough() { settings.setClickThrough(!settings.effectiveClickThrough) }
    @objc private func toggleDropPreview() { settings.dropPreviewEnabled.toggle() }
    @objc private func toggleTop() { settings.alwaysOnTop.toggle() }
    @objc private func centerOverlay() { overlay?.center() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard overlay?.dropCanvas.commitInFlight == true else { return .terminateNow }
        settings.dropStatus = "正在完成已提交的回收；结果返回后可退出"
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stopCapture()
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
    }
}

