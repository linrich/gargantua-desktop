// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit

// All input objects here are freshly generated, outside TestTrashSession. The
// real production path is exercised without opening the user's control switch.
func runRecycleChecks(output: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let root = fm.temporaryDirectory.appendingPathComponent("gargantua-real-trash-validation-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    var checks = ["callbacks_completed": true]
    var actualRows = [[String: Any]]()
    func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if !condition() { checks["callbacks_completed"] = false }
    }
    func run(_ service: FileTrashService, _ urls: [URL]) -> [TrashResult] {
        var result: [TrashResult]?
        service.recycle(urls) { result = $0 }
        waitUntil { result != nil }
        return result ?? []
    }
    func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("Generated ordinary-path fixture: \(name)\n".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        try Data("Generated folder \(name)".utf8).write(to: url.appendingPathComponent("Nested/test.txt"), options: .withoutOverwriting)
        return url
    }
    func snapshot(_ url: URL) throws -> [String: String] {
        var rows = [String: String]()
        func visit(_ path: URL, _ relative: String) throws {
            if try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                rows[relative] = "directory"
                for child in try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                    try visit(child, relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            } else { rows[relative] = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined() }
        }
        try visit(url, "")
        return rows
    }
    func record(_ results: [TrashResult]) {
        for result in results {
            actualRows.append(["source": result.source.path, "destination": result.destination?.path ?? "",
                               "moved": result.moved, "verified": result.verified, "message": result.message])
        }
    }
    var writes = [String]()
    let settings = Settings(persistent: false, preferenceWriter: { key, _ in writes.append(key) })
    checks["switch_defaults_off"] = !settings.realTrashEnabled
    settings.realTrashEnabled = true
    checks["switch_not_persisted"] = writes.isEmpty
    checks["new_settings_still_off"] = !Settings(persistent: false).realTrashEnabled
    settings.dropPreviewEnabled = false
    checks["closing_reception_disarms_real_trash"] = !settings.realTrashEnabled

    var calls = [URL]()
    let mock = FileTrashService(recycler: { url in
        calls.append(url)
        throw NSError(domain: "GeneratedRealTrashProbe", code: 1)
    })
    let canary = try file("disabled-canary.txt"), canaryBefore = try snapshot(canary)
    let disabledResult = run(mock, [canary])
    checks["service_defaults_off_no_call"] = disabledResult.count == 1 && !disabledResult[0].moved && calls.isEmpty
    mock.setEnabled(true)
    _ = run(mock, [canary, URL(fileURLWithPath: "/private" + canary.path)])
    checks["duplicate_finder_alias_rejected"] = calls.isEmpty
    let parent = try folder("Parent")
    _ = run(mock, [parent, parent.appendingPathComponent("Nested/test.txt")])
    checks["parent_child_selection_rejected"] = calls.isEmpty
    _ = run(mock, [URL(string: "file://untrusted-host" + canary.path)!])
    checks["remote_file_host_rejected"] = calls.isEmpty
    _ = run(mock, [URL(fileURLWithPath: "/")])
    checks["filesystem_root_rejected"] = calls.isEmpty
    let link = root.appendingPathComponent("generated-link")
    try fm.createSymbolicLink(at: link, withDestinationURL: canary)
    _ = run(mock, [link])
    checks["symlink_not_followed_or_recycled"] = calls.isEmpty && fm.fileExists(atPath: link.path)
    _ = run(mock, [canary, root.appendingPathComponent("missing")])
    checks["invalid_selection_rejected_before_any_mutation"] = calls.isEmpty
    _ = run(mock, Array(repeating: canary, count: 33))
    checks["oversized_batch_rejected"] = calls.isEmpty
    _ = run(mock, [canary])
    checks["system_error_reported_without_fallback"] = try calls.count == 1 && snapshot(canary) == canaryBefore
    mock.setEnabled(false)
    _ = run(mock, [canary])
    checks["disabled_service_stays_closed"] = calls.count == 1

    let canvas = DropCanvas(frame: CGRect(x: 0, y: 0, width: 640, height: 400),
                            hitMap: DiskHitMap(width: 2, height: 2, surfaceCells: [true, true, true, true]))
    let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = canvas
    let sender = RecycleDragProbe(); sender.draggingDestinationWindow = window
    sender.draggingLocation = CGPoint(x: 320, y: 142)
    defer { canvas.stop(); window.close(); sender.draggingPasteboard.releaseGlobally() }
    func payload(_ urls: [URL]) {
        sender.draggingSequenceNumber += 1
        sender.draggingPasteboard.clearContents(); sender.draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
        sender.items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(CGRect(x: 288, y: 110, width: 64, height: 64), contents: DropArtwork.icons["DOC"])
            return item
        }
    }
    var status = ""; canvas.onStatus = { status = $0 }; canvas.fileTrashService = mock
    payload([canary]); _ = canvas.draggingEntered(sender)
    checks["off_hover_discards_ordinary_url"] = canvas.model.tokens.first?.recycleFileURL == nil && canvas.timerRunning
    _ = canvas.performDragOperation(sender)
    checks["off_drop_is_visual_only"] = canvas.model.phase == .falling && !canvas.commitInFlight && calls.count == 1
    canvas.advanceFrame(time: canvas.model.started + 3)
    checks["off_preserves_generated_canary"] = try snapshot(canary) == canaryBefore
    payload([canary]); _ = canvas.draggingEntered(sender)
    canvas.realTrashEnabled = true
    checks["enabling_mid_drag_cancels_old_hover"] = canvas.model.phase == .idle && !canvas.performDragOperation(sender)
    payload([canary]); _ = canvas.draggingEntered(sender)
    checks["new_enabled_hover_retains_url"] = canvas.model.tokens.first?.recycleFileURL != nil
    canvas.realTrashEnabled = false
    checks["disabling_before_release_prevents_operation"] = !canvas.performDragOperation(sender) && calls.count == 1

    // Four ordinary-path objects, explicitly guarded by the generated root in
    // the test harness only. Production has no fixture-registration shortcut.
    let urls = try [file("ordinary-A.txt"), file("ordinary-B.txt"), folder("ordinary-C"), folder("ordinary-D")]
    let before = try urls.map(snapshot)
    let allowedNames = Set(urls.map(\.lastPathComponent))
    let actual = FileTrashService(recycler: { url in
        guard url.deletingLastPathComponent().lastPathComponent == root.lastPathComponent,
              allowedNames.contains(url.lastPathComponent) else { throw NSError(domain: "FixtureBoundary", code: 1) }
        return try FileTrashService.systemTrash(url)
    })
    canvas.fileTrashService = actual; canvas.realTrashEnabled = true
    payload(urls); _ = canvas.draggingEntered(sender)
    checks["ordinary_batch_hover_has_four_tokens"] = canvas.model.tokens.count == 4 && canvas.model.tokens.allSatisfy { $0.recycleTestURL == nil }
    checks["ordinary_folder_icons_preserved"] = canvas.model.tokens.map(\.kind) == ["DOC", "DOC", "DIR", "DIR"]
    checks["ordinary_batch_release_commits"] = canvas.prepareForDragOperation(sender) && canvas.performDragOperation(sender) && canvas.commitInFlight
    checks["ordinary_batch_waits_for_system_before_fall"] = canvas.model.phase == .hovering
    checks["second_drop_while_pending_rejected"] = !canvas.performDragOperation(sender)
    canvas.draggingEnded(sender)
    waitUntil { !canvas.commitInFlight }
    let results = canvas.lastRecycleResults; record(results)
    checks["ordinary_four_actual_trash_results"] = results.count == 4 && results.allSatisfy { $0.moved && $0.verified }
    checks["ordinary_sources_gone"] = urls.allSatisfy { !fm.fileExists(atPath: $0.path) }
    checks["ordinary_destinations_content_verified_by_harness"] = try results.count == 4 && zip(results, before).allSatisfy { result, expected in
        guard let destination = result.destination else { return false }
        return try snapshot(destination) == expected
    }
    checks["ordinary_success_uses_existing_animation"] = canvas.model.phase == .falling && canvas.model.tokens.count == 4 && canvas.timerRunning
    canvas.advanceFrame(time: canvas.model.started + 3)
    checks["ordinary_success_status_has_no_content_hash_claim"] = status.contains("4 个项目") && status.contains("位置核对") && !status.contains("内容核对")

    // Partial system failure: only the successfully recycled generated item animates.
    let good = try file("partial-good.txt"), bad = try file("partial-failure.txt")
    let partial = FileTrashService(recycler: { url in
        guard url.deletingLastPathComponent().lastPathComponent == root.lastPathComponent else { throw NSError(domain: "FixtureBoundary", code: 2) }
        if url.lastPathComponent == bad.lastPathComponent { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        guard url.lastPathComponent == good.lastPathComponent else { throw NSError(domain: "FixtureBoundary", code: 3) }
        return try FileTrashService.systemTrash(url)
    })
    canvas.realTrashEnabled = false; canvas.fileTrashService = partial; canvas.realTrashEnabled = true
    payload([good, bad]); _ = canvas.draggingEntered(sender); _ = canvas.performDragOperation(sender)
    waitUntil { !canvas.commitInFlight }; record(canvas.lastRecycleResults)
    checks["partial_failure_only_success_animates"] = canvas.model.phase == .falling && canvas.model.tokens.count == 1 && fm.fileExists(atPath: bad.path)
    checks["partial_failure_names_failed_item"] = status.contains(bad.lastPathComponent) && status.contains("1 个未成功")
    canvas.advanceFrame(time: canvas.model.started + 3)

    // Deterministic cancellation between two items. The first entered system
    // operation is allowed to finish; disable/re-enable must not revive item 2.
    let first = try file("cancel-first.txt"), second = try file("cancel-second.txt")
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    var cancelCalls = 0
    let cancellable = FileTrashService(recycler: { url in
        cancelCalls += 1; entered.signal()
        guard resume.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "ProbeTimeout", code: 1) }
        guard url.deletingLastPathComponent().lastPathComponent == root.lastPathComponent,
              url.lastPathComponent == first.lastPathComponent else { throw NSError(domain: "FixtureBoundary", code: 4) }
        return try FileTrashService.systemTrash(url)
    })
    canvas.realTrashEnabled = false; canvas.fileTrashService = cancellable; canvas.realTrashEnabled = true
    payload([first, second]); _ = canvas.draggingEntered(sender); _ = canvas.performDragOperation(sender)
    checks["cancellation_probe_entered_first_call"] = entered.wait(timeout: .now() + 5) == .success
    canvas.realTrashEnabled = false; canvas.realTrashEnabled = true
    resume.signal(); waitUntil { !canvas.commitInFlight }; record(canvas.lastRecycleResults)
    checks["disable_reenable_cannot_revive_pending_items"] = cancelCalls == 1 && canvas.lastRecycleResults.count == 2 && canvas.lastRecycleResults[0].moved && !canvas.lastRecycleResults[1].moved
    checks["unstarted_item_remains_at_source"] = fm.fileExists(atPath: second.path)
    checks["cancelled_generation_does_not_resume_animation"] = canvas.model.phase == .idle && !canvas.timerRunning
    checks["completed_operation_still_reported_after_disable"] = status.contains("已移入系统废纸篓：1 个项目")
    canvas.realTrashEnabled = false
    checks["generated_canary_untouched_through_all_tests"] = try snapshot(canary) == canaryBefore

    let report: [String: Any] = ["scope": "Only newly generated ordinary-path fixtures; synthetic destination callbacks. User-facing switch never enabled by this test.",
        "passed": checks.values.allSatisfy { $0 }, "check_count": checks.count, "checks": checks,
        "generated_root": root.path, "results": actualRows, "before_batch": before]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("report.json"))
    print("Real trash opt-in checks: \(checks.values.filter { $0 }.count)/\(checks.count)")
    guard checks.values.allSatisfy({ $0 }) else { throw NSError(domain: "RealTrashValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")]) }
}

// Private pasteboard, generated payloads, synthetic destination callbacks only.
private final class RecycleDragProbe: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = CGPoint.zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { DropArtwork.icons["DOC"] }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 42
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = true
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight = NSSpringLoadingHighlight.none
    var items = [NSDraggingItem]()
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for (index, item) in items.enumerated() { block(item, index, &stop); if stop.boolValue { break } }
    }
    func setPayload(_ payload: NSPasteboardItem) {
        // Pasteboard items are single-pasteboard objects. Copy this generated
        // fixture's bytes instead of reusing a previously attached item.
        let fresh = NSPasteboardItem()
        for type in payload.types { if let data = payload.data(forType: type) { fresh.setData(data, forType: type) } }
        draggingPasteboard.clearContents(); draggingPasteboard.writeObjects([fresh])
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(CGRect(x: draggingLocation.x - 32, y: draggingLocation.y - 32, width: 64, height: 64),
                              contents: DropArtwork.icons["DOC"])
        items = [item]
    }
}
