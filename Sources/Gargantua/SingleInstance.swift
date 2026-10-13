// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin

// The descriptor owns the lease. Never unlink the file: replacing its inode
// would let another process acquire a different lock at the same path.
final class InstanceLease {
    private var descriptor: Int32 = -1
    let acquired: Bool

    init(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RenderError.unavailable("无法建立单实例锁：\(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            acquired = true
        } else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK else {
                throw RenderError.unavailable("无法检查运行实例：\(String(cString: strerror(code)))")
            }
            acquired = false
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

enum AppInstance {
    static let bundleIdentifier = "local.gargantua.desktop"
    static let reopenNotification = Notification.Name("local.gargantua.desktop.reopen-controls")

    static func acquire() throws -> InstanceLease? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != pid && !$0.isTerminated }
            .sorted { $0.processIdentifier < $1.processIdentifier }

        // Also respect an already running pre-lock version during upgrades.
        if let existing = peers.first(where: { $0.isFinishedLaunching }) {
            focus(existing)
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleIdentifier).instance.lock")
        let lease = try InstanceLease(url: url)
        guard lease.acquired else {
            if let existing = peers.first { focus(existing) }
            return nil
        }
        return lease
    }

    private static func focus(_ app: NSRunningApplication) {
        // Only an empty, process-addressed local notification; no settings,
        // captured frames or other user data leave the running App.
        DistributedNotificationCenter.default().postNotificationName(reopenNotification,
            object: String(app.processIdentifier), userInfo: nil, deliverImmediately: true)
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

}
