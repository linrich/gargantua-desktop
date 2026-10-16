// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct TrashResult {
    let source: URL
    let destination: URL?
    let moved: Bool
    let verified: Bool
    let message: String
}

// Explicit, non-persistent opt-in. No content/thumbnail reads, recursive scans,
// permanent deletion, fallback move, path logging, or automatic retries.
final class FileTrashService {
    typealias Recycler = (URL) throws -> URL?
    private let recycler: Recycler
    private let queue = DispatchQueue(label: "local.gargantua.file-trash", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var busy = false

    init(recycler: @escaping Recycler = FileTrashService.systemTrash) { self.recycler = recycler }
    static func systemTrash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled != value { enabled = value; generation += 1 }
    }
    func cancelPending() {
        lock.lock(); generation += 1; lock.unlock()
    }
    private func permitted(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && generation == token
    }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino; kind = info.st_mode & S_IFMT }
    }
    private struct Item {
        let original: URL
        let url: URL
        let identity: Identity
    }
    private static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }
    private static func physicalPath(_ path: String) throws -> String {
        guard let pointer = realpath(path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    private static func prepare(_ input: URL) throws -> Item {
        guard input.isFileURL, input.host.map({ $0.isEmpty || $0 == "localhost" }) != false,
              input.query == nil, input.fragment == nil, input.path.hasPrefix("/"), !input.path.contains("\0") else {
            throw NSError(domain: "FileTrashInput", code: 1)
        }
        let standard = input.standardizedFileURL
        guard standard.path != "/", !standard.lastPathComponent.isEmpty else { throw NSError(domain: "FileTrashInput", code: 2) }
        // Resolve the parent only. Never resolve a dropped symlink into its target.
        let parent = URL(fileURLWithPath: try physicalPath(standard.deletingLastPathComponent().path), isDirectory: true)
        let url = parent.appendingPathComponent(standard.lastPathComponent)
        let metadata = try info(url), identity = Identity(metadata)
        guard identity.kind == S_IFREG || identity.kind == S_IFDIR else { throw NSError(domain: "FileTrashInput", code: 3) }
        if identity.kind == S_IFDIR {
            let home = try physicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
            guard url.path != home, (try info(parent)).st_dev == metadata.st_dev else {
                throw NSError(domain: "FileTrashInput", code: 2)
            }
        }
        return Item(original: input, url: url, identity: identity)
    }
    private static func failure(_ url: URL, _ text: String) -> TrashResult {
        TrashResult(source: url, destination: nil, moved: false, verified: false, message: text)
    }

    func recycle(_ urls: [URL], completion: @escaping ([TrashResult]) -> Void) {
        lock.lock()
        guard enabled, !busy, !urls.isEmpty, urls.count <= 32 else {
            lock.unlock()
            DispatchQueue.main.async { completion(urls.map { Self.failure($0, "真实回收未开启、正在处理或项目数量超限；未执行回收") }) }
            return
        }
        busy = true
        let token = generation
        lock.unlock()
        queue.async {
            var results: [TrashResult]
            if !self.permitted(token) {
                results = urls.map { Self.failure($0, "真实回收已关闭或拖放已取消；未执行回收") }
            } else {
                // Prepare the whole selection before any mutation, so duplicate
                // aliases and a parent+descendant selection cannot partly execute.
                do {
                    let items = try urls.map(Self.prepare)
                    let paths = items.map { $0.url.path }
                    let overlaps = paths.enumerated().contains { i, path in
                        paths.enumerated().contains { j, other in i != j && (path == other || path.hasPrefix(other + "/")) }
                    }
                    if overlaps {
                        results = urls.map { Self.failure($0, "包含重复项目或父子目录；请分开拖入，本次未执行回收") }
                    } else {
                        results = items.map { item in
                            guard self.permitted(token) else { return Self.failure(item.original, "真实回收已关闭或拖放已取消；未执行回收") }
                            guard let current = try? Self.info(item.url), Identity(current) == item.identity else {
                                return Self.failure(item.original, "项目已改变或缺失；未执行回收")
                            }
                            // Check once more immediately before the system call.
                            guard self.permitted(token) else { return Self.failure(item.original, "真实回收已关闭或拖放已取消；未执行回收") }
                            do {
                                let destination = try self.recycler(item.url)
                                var sourceInfo = stat()
                                let gone = lstat(item.url.path, &sourceInfo) != 0 && errno == ENOENT
                                let verified = gone && destination.flatMap { try? Self.info($0) }.map { Identity($0) == item.identity } == true
                                return TrashResult(source: item.original, destination: destination, moved: true, verified: verified,
                                    message: verified ? "已移入系统废纸篓，位置核对通过" : "系统报告已回收，返回位置未能核验")
                            } catch {
                                let error = error as NSError
                                return Self.failure(item.original, "系统回收失败（\(error.domain) \(error.code)）；未执行删除")
                            }
                        }
                    }
                } catch {
                    let error = error as NSError
                    let reason = error.domain == "FileTrashInput" ? "仅接收本地普通文件和文件夹，不接收符号链接、主目录或卷根目录" : "项目不可访问或已缺失"
                    results = urls.map { Self.failure($0, reason + "；整组未执行回收") }
                }
            }
            self.lock.lock(); self.busy = false; self.lock.unlock()
            DispatchQueue.main.async { completion(results) }
        }
    }
}
