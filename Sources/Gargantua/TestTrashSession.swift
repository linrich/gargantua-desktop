// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

// This stage has no API to register existing files. Only fixture creation can
// mint eligibility, and registrations live for this process/session only.
final class TestTrashSession {
    typealias Recycler = (URL) throws -> URL?
    private let recycler: Recycler
    init(recycler: @escaping Recycler = TestTrashSession.systemTrash) { self.recycler = recycler }
    static func systemTrash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private struct Node {
        let identity: Identity
        let bytes: Data? // nil means a generated directory, including empty directories.
    }
    private struct Entry {
        let url: URL
        let nodes: [String: Node] // Relative names, with "" for the registered top-level object.
        var claimed = false
        var isDirectory: Bool { nodes[""]?.bytes == nil }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.gargantua.generated-trash", qos: .userInitiated)
    private var entries = [String: Entry]()
    private var generatedAliases = [String: String]()
    private var rootIdentity: Identity?
    private var receipts = [[String: Any]]()
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("gargantua-trash-tests-\(UUID().uuidString)", isDirectory: true)
    var receiptURL: URL { root.appendingPathComponent("receipts.json") }

    private static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }
    private func validRoot() -> Bool {
        guard let expected = rootIdentity, let info = try? Self.metadata(root) else { return false }
        return Identity(info) == expected && info.st_mode & S_IFMT == S_IFDIR
            && root.resolvingSymlinksInPath().path == root.path
    }

    func createFixture(isDirectory: Bool = false) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if rootIdentity == nil {
            // Resolve the OS temp-directory alias once, not arbitrary drag URLs.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            rootIdentity = Identity(try Self.metadata(root))
        }
        guard validRoot() else { throw NSError(domain: "GargantuaTestTrash", code: 1) }
        let id = UUID().uuidString
        let url = root.appendingPathComponent("Gargantua-TEST-\(id)" + (isDirectory ? "-Folder" : ".txt"), isDirectory: isDirectory)
        let data = Data("Gargantua generated disposable test file.\nID: \(id)\nNo user content.\n".utf8)
        var nodes = [String: Node]()
        func addDirectory(_ relative: String) throws {
            let target = relative.isEmpty ? url : url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            nodes[relative] = Node(identity: Identity(try Self.metadata(target)), bytes: nil)
        }
        func addFile(_ relative: String, _ bytes: Data) throws {
            let target = relative.isEmpty ? url : url.appendingPathComponent(relative)
            try bytes.write(to: target, options: .withoutOverwriting)
            nodes[relative] = Node(identity: Identity(try Self.metadata(target)), bytes: bytes)
        }
        if isDirectory {
            try addDirectory("")
            try addDirectory("Nested")
            try addDirectory("Nested/Empty")
            try addFile("README-TEST.txt", data)
            try addFile("Nested/测试内容.txt", Data("Generated nested test content.\nID: \(id)\n".utf8))
            try addFile("Nested/payload.bin", Data((0..<256).map { UInt8($0) }))
        } else { try addFile("", data) }
        // Finder may vend /private/var while Foundation vends /var. Resolve
        // only our just-created object, never an arbitrary incoming drag URL.
        guard let physical = realpath(url.path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let physicalPath = String(cString: physical); free(physical)
        entries[url.path] = Entry(url: url, nodes: nodes)
        generatedAliases[physicalPath] = url.path
        return url
    }

    func createFixtureBatch() throws -> [URL] {
        try [false, false, true, true].map { try createFixture(isDirectory: $0) }
    }

    private func registeredKey(_ url: URL) -> String? {
        guard url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) != false else { return nil }
        if entries[url.path] != nil { return url.path }
        return generatedAliases[url.path]
    }

    // Lookup never reads/stat()s an unregistered URL or follows its symlinks.
    func isRegistered(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registeredKey(url) != nil
    }

    func registeredKind(_ url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let key = registeredKey(url), let entry = entries[key] else { return nil }
        return entry.isDirectory ? "DIR" : "DOC"
    }

    private func matches(_ entry: Entry, at url: URL) -> Bool {
        // Walk only the known generated tree with fd-relative, no-follow opens.
        // Enumerate names before opening children, rejecting unexpected content.
        func check(_ fd: Int32, relative: String) -> Bool {
            guard let node = entry.nodes[relative] else { return false }
            var info = stat()
            guard fstat(fd, &info) == 0, Identity(info) == node.identity else { return false }
            if let expected = node.bytes {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                      info.st_size == expected.count else { return false }
                var bytes = [UInt8](repeating: 0, count: expected.count + 1)
                let count = read(fd, &bytes, bytes.count)
                return count == expected.count && Data(bytes.prefix(count)) == expected
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { return false }
            let duplicate = dup(fd)
            guard duplicate >= 0 else { return false }
            guard let directory = fdopendir(duplicate) else { close(duplicate); return false }
            defer { closedir(directory) }
            var names = Set<String>()
            errno = 0
            while let item = readdir(directory) {
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.insert(name) }
            }
            guard errno == 0 else { return false }
            let prefix = relative.isEmpty ? "" : relative + "/"
            let expectedNames = Set(entry.nodes.keys.compactMap { path -> String? in
                guard path.hasPrefix(prefix), path != relative else { return nil }
                let rest = String(path.dropFirst(prefix.count))
                return rest.contains("/") ? nil : rest
            })
            guard names == expectedNames else { return false }
            for name in names {
                let path = prefix + name
                let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (entry.nodes[path]?.bytes == nil ? O_DIRECTORY : 0)
                let child = openat(fd, name, flags)
                guard child >= 0 else { return false }
                let valid = check(child, relative: path)
                close(child)
                if !valid { return false }
            }
            return true
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (entry.isDirectory ? O_DIRECTORY : 0))
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return check(fd, relative: "")
    }

    private func manifest(_ entry: Entry) -> [[String: Any]] {
        entry.nodes.keys.sorted().map { relative in
            let node = entry.nodes[relative]!
            var row: [String: Any] = ["relative_path": relative, "kind": node.bytes == nil ? "directory" : "file"]
            if let bytes = node.bytes {
                row["size"] = bytes.count
                row["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            return row
        }
    }

    // No fallback deletion, guessed ~/.Trash path, collision overwrite or retry.
    // A failed/uncertain claim is consumed too; generating a new file is explicit.
    func recycle(_ urls: [URL], completion: @escaping ([TrashResult]) -> Void) {
        lock.lock()
        let keys = urls.compactMap { registeredKey($0) }
        guard !urls.isEmpty, urls.count <= 32, keys.count == urls.count, Set(keys).count == urls.count,
              keys.allSatisfy({ entries[$0]?.claimed == false }) else {
            lock.unlock()
            DispatchQueue.main.async { completion(urls.map { TrashResult(source: $0, destination: nil, moved: false, verified: false, message: "未登记或已提交；未执行回收") }) }
            return
        }
        let batch = keys.compactMap { entries[$0] }
        for key in keys { entries[key]?.claimed = true }
        lock.unlock()
        queue.async {
            let results = batch.map { entry -> TrashResult in
                guard self.validRoot(), self.matches(entry, at: entry.url) else {
                    return TrashResult(source: entry.url, destination: nil, moved: false, verified: false,
                                           message: "测试项目或内部内容已改变或缺失；未执行回收")
                }
                do {
                    let resultURL = try self.recycler(entry.url)
                    let sourceGone = !FileManager.default.fileExists(atPath: entry.url.path)
                    let verified = sourceGone && resultURL.map { self.matches(entry, at: $0) } == true
                    return TrashResult(source: entry.url, destination: resultURL, moved: true, verified: verified,
                                           message: verified ? "已移入系统废纸篓，全部内容核对通过" : "系统报告已移入废纸篓，落点内容未能核验")
                } catch {
                    let error = error as NSError
                    return TrashResult(source: entry.url, destination: nil, moved: false, verified: false,
                                           message: "系统回收失败（\(error.domain) \(error.code)）；未执行删除")
                }
            }
            self.lock.lock()
            for (entry, result) in zip(batch, results) {
                var receipt: [String: Any] = ["generated_source": entry.url.path,
                    "trash_destination": result.destination?.path ?? "", "moved": result.moved,
                    "verified": result.verified, "message": result.message,
                    "kind": entry.isDirectory ? "directory" : "file", "expected_manifest": self.manifest(entry)]
                if let bytes = entry.nodes[""]?.bytes {
                    receipt["expected_sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                }
                self.receipts.append(receipt)
            }
            if self.validRoot(), let data = try? JSONSerialization.data(withJSONObject: self.receipts, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.receiptURL, options: .atomic)
            }
            self.lock.unlock()
            DispatchQueue.main.async { completion(results) }
        }
    }
}
