// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

enum DropArtwork {
    static let sampleType = NSPasteboard.PasteboardType("local.gargantua.prototype.sample")
    static let gold = NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.34, alpha: 1)
    static let icons: [String: NSImage] = {
        var result = [String: NSImage]()
        for kind in ["DOC", "IMG", "DIR"] {
            let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
                let color: NSColor = kind == "IMG" ? .systemPurple : (kind == "DIR" ? .systemBlue : .systemTeal)
                NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 10, y: 3, width: 44, height: 58), xRadius: 6, yRadius: 6).fill()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 10, y: 3, width: 44, height: 20), xRadius: 5, yRadius: 5).fill()
                (kind as NSString).draw(at: NSPoint(x: 19, y: 7), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
                color.withAlphaComponent(0.6).setStroke()
                let lines = NSBezierPath(); lines.lineWidth = 3
                for y in [32.0, 39.0, 46.0] { lines.move(to: NSPoint(x: 20, y: y)); lines.line(to: NSPoint(x: 44, y: y)) }
                lines.stroke()
                return true
            }
            result[kind] = image
        }
        return result
    }()
    static func icon(_ token: DropToken) -> NSImage { icons[token.kind] ?? icons["DOC"]! }

    static func label(_ text: String, at point: CGPoint, size: Double = 12, color: NSColor = .secondaryLabelColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }
}

enum DropPainter {
    static func draw(model: DropInteraction, time: Double, rect: CGRect, reduced: Bool, tint: NSColor) {
        guard model.phase != .idle, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let elapsed = max(0, time - model.started)
        if model.phase == .hovering {
            let distance = hypot(model.point.x - center.x, model.point.y - center.y)
            let jitter = DropMotion.jitter(time: elapsed, proximity: 1 - distance / (rect.width * 0.4), reduced: reduced)
            for (i, token) in model.tokens.prefix(3).enumerated().reversed() {
                let p = CGPoint(x: model.point.x + jitter.x + Double(i) * 9,
                                y: model.point.y + jitter.y + Double(i) * 7)
                drawIcon(token, pose: DropPose(point: p, rotation: reduced ? 0 : sin(elapsed * 70) * 0.035,
                                              scaleX: 1, scaleY: 1, alpha: 1), context: ctx)
            }
            let title = model.tokens.count == 1 ? model.tokens[0].title : "\(model.tokens.count) 个项目"
            DropArtwork.label(title, at: CGPoint(x: model.point.x + 38, y: model.point.y - 6), color: .white)
            return
        }
        for (i, token) in model.tokens.prefix(3).enumerated() {
            let t = max(0, elapsed - Double(i) * 0.09)
            let start = CGPoint(x: model.point.x + Double(i) * 9, y: model.point.y + Double(i) * 7)
            if reduced {
                drawIcon(token, pose: DropPose(point: start, rotation: 0, scaleX: 1, scaleY: 1,
                                              alpha: 1 - bounded(elapsed / 0.32)), context: ctx)
                continue
            }
            let pose = DropMotion.pose(start: start, center: center, time: t)
            let light = smooth(0.26, 0.50, t) * (1 - smooth(0.70, 1.18, t))
            drawLight(context: ctx, center: center, radius: rect.width * 0.14, light: light, tint: tint)
            if t >= 0.30 {
                for index in 0..<30 {
                    let fragment = DropMotion.fragment(start: start, center: center, index: index, time: t)
                    guard fragment.alpha > 0.001 else { continue }
                    let tail = DropMotion.fragment(start: start, center: center, index: index, time: max(0.30, t - 0.06))
                    if t > 0.44 {
                        ctx.saveGState(); ctx.setBlendMode(.plusLighter)
                        let path = CGMutablePath(); path.move(to: tail.point)
                        path.addQuadCurve(to: fragment.point, control: CGPoint(x: (tail.point.x + fragment.point.x) / 2 + 5,
                                                                              y: (tail.point.y + fragment.point.y) / 2 + 3))
                        ctx.addPath(path); ctx.setStrokeColor(tint.withAlphaComponent(fragment.alpha * 0.13).cgColor)
                        ctx.setLineWidth(5); ctx.strokePath()
                        ctx.addPath(path); ctx.setStrokeColor(tint.withAlphaComponent(fragment.alpha * 0.8).cgColor)
                        ctx.setLineWidth(0.9); ctx.strokePath(); ctx.restoreGState()
                    }
                    drawFragment(token, pose: fragment, index: index, context: ctx)
                }
            }
            if pose.alpha > 0 { drawIcon(token, pose: pose, context: ctx) }
        }
    }

    private static func drawIcon(_ token: DropToken, pose: DropPose, context: CGContext) {
        guard pose.alpha > 0 else { return }
        context.saveGState(); context.translateBy(x: pose.point.x, y: pose.point.y)
        context.rotate(by: pose.rotation); context.scaleBy(x: pose.scaleX, y: pose.scaleY)
        DropArtwork.icon(token).draw(in: CGRect(x: -32, y: -32, width: 64, height: 64),
                                    from: .zero, operation: .sourceOver, fraction: pose.alpha)
        context.restoreGState()
    }

    private static func drawFragment(_ token: DropToken, pose: DropPose, index: Int, context: CGContext) {
        context.saveGState(); context.translateBy(x: pose.point.x, y: pose.point.y)
        context.rotate(by: pose.rotation); context.scaleBy(x: pose.scaleX, y: pose.scaleY)
        let w = 64.0 / 5, h = 64.0 / 6
        let crop = CGRect(x: Double(index % 5) * w, y: Double(index / 5) * h, width: w, height: h)
        DropArtwork.icon(token).draw(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                    from: crop, operation: .sourceOver, fraction: pose.alpha)
        context.restoreGState()
    }

    private static func drawLight(context: CGContext, center: CGPoint, radius: Double, light: Double, tint: NSColor) {
        guard light > 0 else { return }
        context.saveGState(); context.setBlendMode(.plusLighter)
        // Short planar streaks, never a receiver ring or a full-screen flash.
        for offset in [-3.0, 0, 3.0] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x - radius, y: center.y + offset))
            path.addCurve(to: CGPoint(x: center.x + radius, y: center.y + offset),
                          control1: CGPoint(x: center.x - radius * 0.25, y: center.y + offset + 5),
                          control2: CGPoint(x: center.x + radius * 0.25, y: center.y + offset + 5))
            context.addPath(path); context.setLineWidth(offset == 0 ? 6 : 3)
            context.setStrokeColor(tint.withAlphaComponent(light * 0.06).cgColor); context.strokePath()
            context.addPath(path); context.setLineWidth(0.8)
            context.setStrokeColor(tint.withAlphaComponent(light * (offset == 0 ? 0.6 : 0.2)).cgColor); context.strokePath()
        }
        context.restoreGState()
    }
}

private struct DragAppearance {
    let offset: CGPoint
    let size: CGSize
    let components: [NSDraggingImageComponent]
}

final class DropCanvas: NSView {
    let model = DropInteraction()
    var background: NSImage?
    var hitMap: DiskHitMap
    var tint = DropArtwork.gold
    var onStatus: ((String) -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var trashSession: TestTrashSession? {
        didSet { updateDropAccessibility() }
    }
    private func updateDropAccessibility() {
        setAccessibilityLabel(realTrashEnabled ? "黑洞拖放；松手移入系统废纸篓"
            : (trashSession == nil ? "黑洞拖放；文件和文件夹只演示" : "黑洞拖放；普通文件只演示，专用测试文件可回收"))
    }
    var fileTrashService = FileTrashService()
    var realTrashEnabled = false {
        didSet {
            guard realTrashEnabled != oldValue else { return }
            fileTrashService.setEnabled(realTrashEnabled && receptionEnabled)
            stop() // Never retroactively arm a hover that began in demo mode.
            updateDropAccessibility()
            onStatus?(realTrashEnabled ? "真实回收已开启；请重新拖入文件或文件夹" : "真实回收已关闭；尚未开始的回收已取消")
        }
    }
    private(set) var commitInFlight = false
    private(set) var lastRecycleResults = [TrashResult]()
    private var animationGeneration = 0
    private var completionStatus = "演示完成 · 没有移动、复制或删除文件"
    // Opt-in only in the generated-file diagnostic board. Records counts and
    // operation bits, never file names, URLs, contents or pasteboard bytes.
    var diagnosticFileEvents = false
    var receptionEnabled = true {
        didSet {
            fileTrashService.setEnabled(realTrashEnabled && receptionEnabled)
            if !receptionEnabled { stop() }
        }
    }
    var reduceMotionOverride = false
    var reduced: Bool { reduceMotionOverride || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var timer: Timer?
    private var dragAppearances = [Int: DragAppearance]()
    private var currentSender: NSDraggingInfo?
    private var inputTokens = [DropToken]()
    private var activeSequence: Int?
    private var nativeHidden = false
    private var demoStarted: Double?
    private var sleepingObserver: NSObjectProtocol?
    private var syntheticSequence = false
    private var tracedHoverFrames = 0
    private var tracedFallPoint: CGPoint?
    private var tracedFracture = false
    var nativeEntered = 0
    var nativeHovered = 0
    var nativeReleased = 0
    var nativeCancelled = 0
    var animationFrames = 0
    var timerRunning: Bool { timer != nil }

    init(frame: CGRect, background: NSImage? = nil, hitMap: DiskHitMap) {
        self.background = background; self.hitMap = hitMap
        super.init(frame: frame)
        wantsLayer = true; layer?.isOpaque = false; layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([DropArtwork.sampleType, .fileURL])
        setAccessibilityIdentifier("drop-canvas")
        updateDropAccessibility()
        sleepingObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                              object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    deinit {
        timer?.invalidate()
        if let sleepingObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepingObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let background {
            NSColor(calibratedRed: 0.022, green: 0.026, blue: 0.04, alpha: 1).setFill(); bounds.fill()
            background.draw(in: bounds)
        } else {
            NSGraphicsContext.current?.cgContext.clear(bounds)
        }
        let drawTime = CACurrentMediaTime()
        DropPainter.draw(model: model, time: drawTime, rect: bounds, reduced: reduced, tint: tint)
        let traceGeneratedFile = diagnosticFileEvents && !model.tokens.isEmpty && model.tokens.allSatisfy { $0.recycleTestURL != nil }
        if (syntheticSequence || traceGeneratedFile) && model.phase == .hovering {
            tracedHoverFrames += 1
            if tracedHoverFrames == 1 || tracedHoverFrames == 3 {
                let distance = hypot(model.point.x - bounds.midX, model.point.y - bounds.midY)
                let jitter = DropMotion.jitter(time: max(0, drawTime - model.started), proximity: 1 - distance / (bounds.width * 0.4), reduced: reduced)
                NativeTrace.record("hover_draw", point: model.point,
                                   detail: "frame=\(tracedHoverFrames), reduced=\(reduced), jitterX=\(jitter.x), jitterY=\(jitter.y)")
            }
        }
        if let point = tracedFallPoint, model.phase == .falling,
           CACurrentMediaTime() - model.started >= 0.44, !tracedFracture {
            tracedFracture = true; NativeTrace.record("fracture_and_light_draw", point: point)
        }
    }

    // COPY prevents source-side move/delete cleanup. The opted-in destination
    // alone calls system Trash after release; disabled ordinary drops only animate.
    static func safeOperation(_ source: NSDragOperation) -> NSDragOperation {
        source.contains(.copy) ? .copy : []
    }

    private func tokens(from sender: NSDraggingInfo) -> [DropToken] {
        guard let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty, items.count <= 32 else { return [] }
        var result = [DropToken]()
        for item in items {
            if let indexText = item.string(forType: DropArtwork.sampleType), let index = Int(indexText), DropToken.samples.indices.contains(index) {
                result.append(DropToken.samples[index])
            } else if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                let ext = url.pathExtension.lowercased()
                let kind = trashSession?.registeredKind(url) ?? (url.hasDirectoryPath ? "DIR" : (["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) ? "IMG" : "DOC"))
                let eligible = trashSession?.isRegistered(url) == true
                result.append(DropToken(kind: kind, title: url.lastPathComponent, recycleTestURL: eligible ? url : nil, recycleFileURL: realTrashEnabled ? url : nil))
            } else { return [] } // No promised files, URL downloads, content reads, or mixed payloads.
        }
        return result
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard receptionEnabled, !commitInFlight, !model.busy, demoStarted == nil else { return [] }
        clearNative(restore: true)
        nativeEntered += 1; activeSequence = sender.draggingSequenceNumber
        inputTokens = tokens(from: sender); currentSender = sender
        syntheticSequence = sender.draggingPasteboard.pasteboardItems?.allSatisfy { $0.types.contains(DropArtwork.sampleType) } == true
        if diagnosticFileEvents && !syntheticSequence {
            NativeTrace.record("file_destination_enter", point: convert(sender.draggingLocation, from: nil),
                               detail: "items=\(sender.draggingPasteboard.pasteboardItems?.count ?? 0), tokens=\(inputTokens.count), operations=\(sender.draggingSourceOperationMask.rawValue)")
        }
        tracedHoverFrames = 0
        if syntheticSequence { NativeTrace.record("destination_enter", point: convert(sender.draggingLocation, from: nil)) }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if commitInFlight { return [] }
        guard receptionEnabled, activeSequence == sender.draggingSequenceNumber, !model.busy,
              !inputTokens.isEmpty, !Self.safeOperation(sender.draggingSourceOperationMask).isEmpty else {
            restoreNative(sender); model.cancel(); stopTimerIfIdle(); return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let inside = hitMap.contains(point, in: bounds)
        let wasHovering = model.phase == .hovering
        if model.hover(point: point, tokens: inputTokens, inside: inside, time: CACurrentMediaTime()) {
            if syntheticSequence && !wasHovering { NativeTrace.record("hover_accepted", point: point) }
            if !nativeHidden { nativeHovered += 1; hideNative(sender) }
            let testCount = inputTokens.filter { $0.recycleTestURL != nil }.count
            onStatus?(realTrashEnabled && inputTokens.allSatisfy { $0.recycleFileURL != nil }
                ? "真实回收已开启 · 松手将 \(inputTokens.count) 个项目移入系统废纸篓"
                : testCount == inputTokens.count
                ? "本次生成的 \(testCount) 个测试文件 · 松手移入系统废纸篓"
                : (testCount == 0 ? "吸积盘内 · 松手只演示，普通文件不变" : "测试文件与普通文件混合；请分开拖入，本次不会回收"))
            startTimer(); needsDisplay = true
            return .copy
        }
        restoreNative(sender); stopTimerIfIdle(); needsDisplay = true
        if syntheticSequence && wasHovering { NativeTrace.record("hover_left", point: point) }
        onStatus?("拖入吸积盘轮廓内后图标会抖动，盘与黑洞之间的空隙也可松手")
        return []
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        if let sender, model.phase == .hovering { hideNative(sender) }
    }

    private func hideNative(_ sender: NSDraggingInfo) {
        let pointer = convert(sender.draggingLocation, from: nil)
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            if self.dragAppearances[index] == nil {
                self.dragAppearances[index] = DragAppearance(
                    offset: CGPoint(x: item.draggingFrame.minX - pointer.x, y: item.draggingFrame.minY - pointer.y),
                    size: item.draggingFrame.size, components: item.imageComponents ?? [])
            }
            // AppKit explicitly defines a nil provider as having no drag image.
            // A blank NSImage can be normalized/cached differently by the drag manager.
            item.imageComponentsProvider = nil
        }
        nativeHidden = true
    }

    private func restoreNative(_ sender: NSDraggingInfo) {
        guard nativeHidden else { return }
        let pointer = convert(sender.draggingLocation, from: nil)
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            guard let saved = self.dragAppearances[index] else { return }
            item.draggingFrame = CGRect(x: pointer.x + saved.offset.x, y: pointer.y + saved.offset.y,
                                        width: saved.size.width, height: saved.size.height)
            item.imageComponentsProvider = { saved.components }
        }
        nativeHidden = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ready = !draggingUpdated(sender).isEmpty && model.phase == .hovering
        if ready { sender.animatesToDestination = false }
        return ready
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard receptionEnabled, !commitInFlight, activeSequence == sender.draggingSequenceNumber,
              !Self.safeOperation(sender.draggingSourceOperationMask).isEmpty,
              hitMap.contains(convert(sender.draggingLocation, from: nil), in: bounds),
              model.phase == .hovering else { return false }
        let usingReal = realTrashEnabled && inputTokens.contains { $0.recycleFileURL != nil }
        let urls = usingReal ? inputTokens.compactMap(\.recycleFileURL) : inputTokens.compactMap(\.recycleTestURL)
        if !urls.isEmpty {
            guard urls.count == inputTokens.count, usingReal || trashSession != nil else {
                stop(); onStatus?("混合拖入已取消；普通文件与测试文件均未处理")
                return false
            }
            let tokens = inputTokens, point = model.point, generation = animationGeneration
            commitInFlight = true; lastRecycleResults = []
            nativeReleased += 1; clearNative(restore: false)
            onStatus?(usingReal ? "正在移入系统废纸篓…" : "正在将生成测试项目移入系统废纸篓…")
            if !usingReal { NativeTrace.record("test_trash_submitted", point: point, detail: "count=\(urls.count)") }
            let completion: ([TrashResult]) -> Void = { [weak self] results in
                guard let self else { return }
                self.commitInFlight = false; self.lastRecycleResults = results
                let moved = results.filter(\.moved).count
                let unverified = results.filter { $0.moved && !$0.verified }.count
                let failed = results.count - moved
                let status: String
                if moved == 0 { status = results.first?.message ?? "未执行回收" }
                else {
                    status = "已移入系统废纸篓：\(moved) 个" + (usingReal ? "项目" : "生成测试项目")
                        + (failed > 0 ? "；\(failed) 个未成功，未执行删除" : "")
                        + (unverified > 0 ? "；\(unverified) 个返回位置未能核验" : (usingReal ? "；位置核对通过" : "；内容核对通过"))
                        + (usingReal && failed > 0 ? "\n" + results.filter { !$0.moved }.map { "\($0.source.lastPathComponent)：\($0.message)" }.joined(separator: "\n") : "")
                }
                if !usingReal {
                    NativeTrace.record("test_trash_result", point: point,
                                       detail: "moved=\(moved), failed=\(failed), unverified=\(unverified)")
                }
                self.completionStatus = status
                if generation == self.animationGeneration, self.receptionEnabled, moved > 0 {
                    let accepted = zip(tokens, results).compactMap { token, result in result.moved ? token : nil }
                    _ = self.model.hover(point: point, tokens: accepted, inside: true, time: CACurrentMediaTime())
                    _ = self.model.release(time: CACurrentMediaTime())
                    self.tracedFallPoint = usingReal ? nil : point; self.tracedFracture = false
                    self.startTimer()
                } else { self.model.reset(); self.stopTimerIfIdle() }
                self.needsDisplay = true; self.onStatus?(status)
            }
            if usingReal { fileTrashService.recycle(urls, completion: completion) }
            else { trashSession!.recycle(urls, completion: completion) }
            return true
        }
        guard model.release(time: CACurrentMediaTime()) else { return false }
        completionStatus = "演示完成 · 没有移动、复制或删除文件"
        nativeReleased += 1
        if syntheticSequence || diagnosticFileEvents {
            tracedFallPoint = model.point; tracedFracture = false
            NativeTrace.record(syntheticSequence ? "release_accepted" : "file_release_accepted", point: model.point)
        }
        clearNative(restore: false); startTimer(); needsDisplay = true
        onStatus?("坠入 → 粉碎 → 光线 · 仅视觉演示，没有回收文件")
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endHover(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { endHover(sender) }
    private func endHover(_ sender: NSDraggingInfo?) {
        if let sender, activeSequence != sender.draggingSequenceNumber { return }
        if model.phase == .hovering { nativeCancelled += 1 }
        clearNative(restore: true); model.cancel(); stopTimerIfIdle(); needsDisplay = true
        if !model.busy { onStatus?("已取消本次拖入 · 文件不变") }
    }
    private func clearNative(restore: Bool) {
        if restore, let sender = currentSender { restoreNative(sender) }
        currentSender = nil; activeSequence = nil; inputTokens = []; dragAppearances = [:]; nativeHidden = false
        syntheticSequence = false
    }

    func playDemo() {
        guard receptionEnabled, !commitInFlight, !model.busy, currentSender == nil else { return }
        completionStatus = "演示完成 · 没有移动、复制或删除文件"
        model.reset(); demoStarted = CACurrentMediaTime(); startTimer()
        onStatus?("生成图标演示：先悬停抖动，再松手吞入；没有真实文件")
    }
    private func startTimer() {
        guard timer == nil else { return }
        let next = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(next, forMode: .common); timer = next
    }
    private func tick() {
        advanceFrame(time: CACurrentMediaTime())
    }
    func advanceFrame(time now: Double) {
        if let started = demoStarted {
            let elapsed = now - started
            if elapsed < 1.0 {
                let p = hitMap.samplePoint(in: bounds)
                _ = model.hover(point: p, tokens: [DropToken.samples[0]], inside: true, time: now)
            } else {
                _ = model.release(time: now); demoStarted = nil
            }
        }
        let before = model.completed
        model.advance(time: now, reduced: reduced)
        animationFrames += 1; needsDisplay = true
        if model.completed > before {
            if let point = tracedFallPoint { NativeTrace.record("completed", point: point); tracedFallPoint = nil }
            onStatus?(completionStatus)
        }
        stopTimerIfIdle()
    }
    private func stopTimerIfIdle() {
        if model.phase == .idle && demoStarted == nil { timer?.invalidate(); timer = nil }
    }
    func stop() {
        fileTrashService.cancelPending()
        animationGeneration += 1
        clearNative(restore: true); model.reset(); demoStarted = nil
        tracedFallPoint = nil
        timer?.invalidate(); timer = nil; needsDisplay = true
    }
}

final class SampleDragView: NSView, NSDraggingSource {
    let index: Int
    let diagnosticProbe: Bool
    init(index: Int, frame: CGRect, diagnosticProbe: Bool = false) {
        self.index = index; self.diagnosticProbe = diagnosticProbe; super.init(frame: frame)
        setAccessibilityIdentifier("sample-\(index)")
        setAccessibilityLabel("拖动\(DropToken.samples[index].title)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard !diagnosticProbe else { return }
        DropArtwork.icon(DropToken.samples[index]).draw(in: CGRect(x: 10, y: 16, width: 42, height: 42))
        DropArtwork.label(DropToken.samples[index].title, at: CGPoint(x: 62, y: 36), color: .white)
        DropArtwork.label("拖入黑洞试试", at: CGPoint(x: 62, y: 16), size: 10)
    }
    override func mouseDown(with event: NSEvent) {
        NativeTrace.record("sample_mouse_down", point: event.locationInWindow, detail: "sample=\(index), hold_probe=\(diagnosticProbe)")
        let payload = NSPasteboardItem(); payload.setString(String(index), forType: DropArtwork.sampleType)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64), contents: DropArtwork.icon(DropToken.samples[index]))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        NativeTrace.record("sample_session_begin", point: window?.convertPoint(fromScreen: screenPoint))
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NativeTrace.record("sample_session_end", point: window?.convertPoint(fromScreen: screenPoint), detail: "operation=\(operation.rawValue)")
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
