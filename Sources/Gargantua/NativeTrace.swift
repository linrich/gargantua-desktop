// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// Prototype diagnostics only: generated sample sessions, canvas coordinates and
// event names. Never record real file payloads, filenames, URLs or global input.
enum NativeTrace {
    static var output: URL?
    private static var events = [[String: Any]]()
    static func record(_ event: String, point: CGPoint? = nil, detail: String = "") {
        guard let output else { return }
        var row: [String: Any] = ["event": event, "time": ProcessInfo.processInfo.systemUptime]
        if let point { row["point"] = [point.x, point.y] }
        if !detail.isEmpty { row["detail"] = detail }
        events.append(row)
        if events.count > 240 { events.removeFirst(events.count - 240) }
        let report: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
                                   "scope": "Generated sample drags only; coordinates local to the prototype window/canvas.",
                                   "events": events]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
}
