// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class TestFileDragView: NSView, NSDraggingSource {
    var fileURL: URL? { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DropArtwork.icon(DropToken.samples[0]).draw(in: CGRect(x: 10, y: 10, width: 42, height: 42))
        DropArtwork.label(fileURL == nil ? "先生成测试文件" : "TEST · 拖入黑洞真实回收", at: CGPoint(x: 62, y: 34), size: 11, color: .white)
        DropArtwork.label("专用测试文件 · 可移入系统废纸篓", at: CGPoint(x: 62, y: 14), size: 10)
    }
    override func mouseDown(with event: NSEvent) {
        guard let fileURL else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64), contents: DropArtwork.icon(DropToken.samples[0]))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
