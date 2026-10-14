// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import MetalKit

final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onMoveEnded: (() -> Void)?
    var onMoveBegan: (() -> Void)?
    var onOpenControls: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onOpenControls?(); return }
        onMoveBegan?()
        window?.performDrag(with: event)
        onMoveEnded?()
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    let window: FloatingPanel
    let view: TransparentMetalView
    let renderer: BlackHoleRenderer
    private let backgroundWindow: FloatingPanel
    private let backgroundView: MTKView
    private let backgroundRenderer: BlackHoleRenderer
    private let desktopCapture: DesktopCapture
    private lazy var backgroundEvents = DesktopEventDriver { [weak self] in
        guard let self, !self.backgroundRenderer.suspended else { return true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.backgroundView.draw()
        CATransaction.commit()
        return self.backgroundRenderer.desktopSurfaceIsCurrent(in:self.backgroundView)
    }
    private var desktopDisplayID: CGDirectDisplayID=0
    private let settings: Settings
    private var asleep = false
    private var sessionInactive = false
    private var applying = false
    private var observers: [NSObjectProtocol] = []
    var onOpenControls: (() -> Void)?

    init(settings: Settings) throws {
        self.settings = settings
        renderer = try BlackHoleRenderer(settings: settings)
        backgroundRenderer = try BlackHoleRenderer(settings:settings,backgroundOnly:true,resources:renderer.resources)
        desktopCapture = DesktopCapture(device:renderer.device)
        let initialScreen=NSScreen.main?.frame.size ?? NSSize(width:1440,height:900)
        let initialWidth=min(settings.size,OverlaySizing.maximumWidth(in:initialScreen))
        let size = NSSize(width: initialWidth, height: initialWidth / OverlaySizing.aspect)
        window = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = DesktopCapturePolicy.overlayTitle
        window.backgroundColor = .clear; window.isOpaque = false
        window.hasShadow = false; window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view = TransparentMetalView(frame: NSRect(origin: .zero, size: size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        // Captured desktop samples are encoded in sRGB. Tag the output too,
        // otherwise unmanaged display RGB creates a coloured/bright patch.
        view.colorspace = CGColorSpace(name:CGColorSpace.sRGB)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.wantsLayer = true; view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.autoResizeDrawable = false
        view.delegate = renderer
        window.contentView = view
        backgroundWindow=FloatingPanel(contentRect:NSRect(origin:.zero,size:initialScreen),
            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        backgroundWindow.title=DesktopCapturePolicy.backgroundTitle
        backgroundWindow.backgroundColor = .clear;backgroundWindow.isOpaque=false;backgroundWindow.hasShadow=false
        backgroundWindow.hidesOnDeactivate=false;backgroundWindow.isReleasedWhenClosed=false
        backgroundWindow.ignoresMouseEvents=true;backgroundWindow.isExcludedFromWindowsMenu=true
        backgroundWindow.collectionBehavior=window.collectionBehavior
        backgroundView=TransparentMetalView(frame:NSRect(origin:.zero,size:initialScreen),device:backgroundRenderer.device)
        backgroundView.colorPixelFormat = .bgra8Unorm;backgroundView.colorspace=CGColorSpace(name:CGColorSpace.sRGB)
        backgroundView.clearColor=MTLClearColorMake(0,0,0,0);backgroundView.framebufferOnly=true
        backgroundView.wantsLayer=true;backgroundView.layer?.isOpaque=false
        backgroundView.layer?.backgroundColor=NSColor.clear.cgColor;backgroundView.autoResizeDrawable=false
        backgroundView.delegate=backgroundRenderer;backgroundView.isPaused=true
        backgroundView.enableSetNeedsDisplay=true
        // The desktop surface stays in screen coordinates. Position changes
        // update only its local lens viewport, never translate captured pixels.
        backgroundView.presentsWithTransaction=true
        backgroundWindow.contentView=backgroundView
        view.onOpenControls = { [weak self] in self?.onOpenControls?() }
        view.onMoveEnded = { [weak self] in self?.savePosition() }
        view.onMoveBegan = { [weak self] in self?.raiseTogether() }
        backgroundRenderer.desktopFrameProvider = { [weak self] in
            guard let self else {return nil}
            return self.desktopCapture.frame(for:self.desktopDisplayID)
        }
        // Initialize on main before the capture queue can use the relay.
        let events=backgroundEvents
        desktopCapture.onFrameChanged = { [weak events] in events?.request() }
        backgroundRenderer.onDesktopInvalidated = { [weak events] in events?.invalidate() }
        desktopCapture.onStatus = { [weak settings] in settings?.desktopStatus=$0 }
        desktopCapture.onFailure = { [weak settings] message in
            settings?.desktopLensing=false;settings?.desktopStatus=message
        }
        if let saved = UserDefaults.standard.string(forKey: "overlayPosition") {
            let point = NSPointFromString(saved)
            if point.x.isFinite && point.y.isFinite { window.setFrameOrigin(point) }
        } else { center() }
        keepOnScreen()
        renderer.onFailure = { [weak self] message in
            guard let self else { return }
            self.settings.rendererError = message
            self.view.isPaused = true
            self.desktopCapture.stop()
            self.settings.desktopLensing=false
            self.settings.desktopStatus="渲染停止，桌面采集已关闭"
        }
        backgroundRenderer.onFailure = { [weak self] message in
            self?.desktopCapture.stop();self?.settings.desktopLensing=false
            self?.settings.desktopStatus="桌面合成停止：\(message)"
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = true; self?.apply()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = false; self?.apply()
            })
        }
        observers.append(workspace.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            self?.sessionInactive=true;self?.apply()
        })
        observers.append(workspace.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            self?.sessionInactive=false;self?.apply()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.keepOnScreen(); self?.apply()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main) { [weak self] _ in
                self?.apply()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.apply()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                // performDrag uses event tracking; don't wait for the normal
                // 30 Hz view timer or write preferences at every pointer step.
                self?.updateDesktop()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName:NSWindow.didChangeOcclusionStateNotification,object:backgroundWindow,queue:.main) { [weak self] _ in
                guard let self, self.backgroundWindow.occlusionState.contains(.visible) else { return }
                self.backgroundRenderer.invalidateDesktopSurface()
            })
        apply()
    }

    func apply(_ changes: SettingsChange = .all) {
        guard !applying else {return}
        applying=true
        defer {applying=false}
        if changes.contains(.layout) {
            let old = window.frame
            let screen = window.screen ?? NSScreen.main
            let available = screen?.frame.size ?? NSSize(width: 1440, height: 900)
            settings.updateSizeLimit(screenSize:available)
            let width = min(CGFloat(settings.size),OverlaySizing.maximumWidth(in:available))
            let size = NSSize(width: width, height: width / OverlaySizing.aspect)
            if abs(old.width - width) > 0.5 {
                window.setFrame(NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2,
                                       width: size.width, height: size.height), display: true)
                keepOnScreen()
            }
            // Use the actual point width, including screen-fit constraints, rather
            // than texture pixels or the slider's requested size.
            if settings.displayedWidth != Double(window.frame.width) {
                settings.displayedWidth = Double(window.frame.width)
            }
            let scale = min(window.backingScaleFactor, settings.quality.pixelScale)
            let cap = min(1.0, Double(RenderDetail.maximumWidth) / (size.width * scale))
            let drawable = CGSize(width: max(1, (size.width * scale * cap).rounded()),
                                  height: max(1, (size.height * scale * cap).rounded()))
            renderer.liveSceneSize=SIMD2(Int(drawable.width),Int(drawable.height))
            // Keep foreground composition at backing resolution while lensing.
            // Disk/PSF textures retain the selected quality; the desktop now has its
            // own native-resolution surface, independent of this panel's bounds.
            let nativeCap=min(1.0,Double(RenderDetail.maximumWidth)/(size.width*window.backingScaleFactor))
            let native=CGSize(width:max(1,(size.width*window.backingScaleFactor*nativeCap).rounded()),
                              height:max(1,(size.height*window.backingScaleFactor*nativeCap).rounded()))
            let output=settings.desktopLensing ? native:drawable
            if view.drawableSize != output { view.drawableSize = output }
            let resolution = "\(Int(drawable.width)) × \(Int(drawable.height)) 像素"
            if settings.renderResolution != resolution { settings.renderResolution = resolution }
        }
        if changes.contains(.window) {
            if window.ignoresMouseEvents != settings.clickThrough { window.ignoresMouseEvents = settings.clickThrough }
            let level: NSWindow.Level = settings.alwaysOnTop ? .floating : .normal
            if window.level != level { window.level = level }
            if settings.visible { raiseTogether() } else { window.orderOut(nil) }
        }
        if changes.contains(.playback) {
            view.preferredFramesPerSecond = settings.targetFPS
            renderer.suspended = !settings.visible || asleep || sessionInactive
            // Synchronize on pause/resume and speed/size changes; appearance
            // sliders no longer reset animation time or the draw timer.
            view.isPaused = settings.paused || settings.speed == 0 || renderer.suspended || settings.rendererError != nil
        }
        if changes.contains(.desktop) { updateDesktop() }
        if !changes.intersection([.appearance, .layout, .playback]).isEmpty &&
            (settings.paused || settings.speed == 0) && !renderer.suspended && settings.rendererError == nil { view.draw() }
    }

    func center() {
        let frame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                      y: frame.midY - window.frame.height / 2))
        keepOnScreen()
        savePosition()
    }

    private func raiseTogether() {
        window.orderFrontRegardless()
        if backgroundWindow.isVisible {backgroundWindow.order(.below,relativeTo:window.windowNumber)}
    }

    private func keepOnScreen() {
        let screens = NSScreen.screens.map(\.frame)
        guard let screen = screens.max(by: { intersectionArea($0, window.frame) < intersectionArea($1, window.frame) }) else { return }
        var frame = window.frame
        frame.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - frame.height))
        window.setFrameOrigin(frame.origin)
    }

    private func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: "overlayPosition")
        updateDesktop()
    }

    private func updateDesktop() {
        guard let screen=window.screen ?? NSScreen.main else {
            backgroundWindow.orderOut(nil);backgroundView.isPaused=true;backgroundRenderer.suspended=true
            backgroundEvents.setActive(false,fps:settings.targetFPS)
            desktopCapture.configure(displayID:nil);return
        }
        // Moving/cropping an NSWindow can expose its previous texture at the
        // new origin before the replacement drawable arrives. Keep the window
        // fixed; a local scissor and disk-shaped shader mask bound the effect.
        let backgroundFrame=screen.frame
        let desktopRect=DesktopCoordinates.rect(overlay:backgroundFrame,screen:screen.frame)
        let viewport=DesktopCoordinates.rect(overlay:window.frame,screen:backgroundFrame)
        let positionChanged=backgroundRenderer.desktopRect != desktopRect || backgroundRenderer.desktopViewport != viewport
        desktopDisplayID=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let active=settings.desktopLensing && settings.desktopStrength>0 && settings.visible && !asleep && !sessionInactive && settings.rendererError==nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {CATransaction.commit()}
        backgroundRenderer.desktopRect=desktopRect
        backgroundRenderer.desktopViewport=viewport
        if backgroundRenderer.suspended != !active {backgroundRenderer.suspended = !active}
        // Never unpause this view: new frames and state changes drive it.
        backgroundEvents.setActive(active,fps:min(30,settings.quality.fps))
        if active {
            let needsOrdering = !backgroundWindow.isVisible || backgroundWindow.level != window.level
            if backgroundWindow.frame != backgroundFrame {backgroundWindow.setFrame(backgroundFrame,display:false)}
            let pixels=DesktopCoordinates.captureSize(points:backgroundFrame.size,pixelScale:Double(screen.backingScaleFactor))
            if backgroundView.drawableSize != pixels {backgroundView.drawableSize=pixels}
            let fps=min(30,settings.quality.fps)
            if backgroundView.preferredFramesPerSecond != fps {backgroundView.preferredFramesPerSecond=fps}
            if backgroundWindow.level != window.level {backgroundWindow.level=window.level}
            // Never briefly lift the background over the foreground on a move.
            if needsOrdering {
                if !window.isVisible {window.orderFrontRegardless()}
                backgroundWindow.order(.below,relativeTo:window.windowNumber)
            }
            if positionChanged || needsOrdering {backgroundView.draw()}
            backgroundEvents.request()
        } else {
            if backgroundWindow.isVisible {backgroundWindow.orderOut(nil)}
        }
        desktopCapture.configure(displayID:active && desktopDisplayID != 0 ? desktopDisplayID:nil,
                                 excludingWindowIDs:Set([window.windowNumber,backgroundWindow.windowNumber].map {$0>0 ? CGWindowID($0):0}))
        if settings.desktopLensing && !active {settings.desktopStatus="已暂停桌面采集（隐藏、休眠或扭曲强度为 0）"}
    }

    func stopCapture() {backgroundEvents.setActive(false,fps:30);desktopCapture.stop()}

    deinit {
        backgroundEvents.setActive(false,fps:30)
        desktopCapture.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
