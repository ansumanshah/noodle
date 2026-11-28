import CoreServices
import Foundation
import NoodleCore

/// Turns changes the Mac makes inside bind-mounted folders into inotify activity in the guest.
///
/// virtiofs never tells the guest kernel about host-side changes, so a watcher inside a container (webpack, vite,
/// nodemon, `tail -F`) hears nothing when an editor saves a file on the Mac. While at least one container with a
/// writable bind mount runs, this watches those folders with FSEvents and asks the agent to `chmod` the changed
/// path (and its folder) to the mode it already has. That is a no-op on disk, but the guest kernel reports it as
/// an attribute change, which every inotify consumer treats as "look again".
/// No stream exists while no such container runs, so an idle daemon has no extra wakeups.
final class HostFileEvents: @unchecked Sendable {
    struct Root: Equatable {
        var key: String          // share key under /mnt/host, e.g. "k<24 hex>w", see HostShareKey
        var path: String         // host directory that is shared
        var only: String?        // single-file bind: only this path is forwarded
    }

    /// More distinct files than this in one burst (npm install, git checkout) are reported as folder changes only.
    static let fileLimit = 200
    static let flagMask = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)

    private let queue = DispatchQueue(label: "app.noodle.hostevents", qos: .utility)
    private let sink: @Sendable ([String]) -> Void
    private var roots: [String: [Root]] = [:]      // container id -> roots (guarded by queue)
    private var stream: FSEventStreamRef?
    private var streamPaths: [String] = []
    /// What each forwarded path looked like. A chmod from `fs_poke` makes the Mac report the same path again with
    /// the old content flags still set, so flags cannot tell an echo from an edit; an unchanged signature can.
    private struct Signature: Equatable { var sec: Int, nsec: Int, size: Int64, ino: UInt64, exists: Bool }
    private var seen: [String: Signature] = [:]
    private static let seenLimit = 8192

    init(sink: @escaping @Sendable ([String]) -> Void) { self.sink = sink }

    /// Register a started container's writable binds. `mounts` are the original (host path) mounts and
    /// `mapped` the same list after `setHostShares` rewrote their sources to `/mnt/host/<key>[/file]`.
    func add(containerID: String, mounts: [GuestMount], mapped: [GuestMount]) {
        var found: [Root] = []
        for (m, g) in zip(mounts, mapped) where m.kind == "bind" && !m.readOnly && g.source.hasPrefix("/mnt/host/") {
            let rel = g.source.dropFirst("/mnt/host/".count)
            let key = String(rel.split(separator: "/", maxSplits: 1).first ?? "")
            var isDir: ObjCBool = false
            guard !key.isEmpty, FileManager.default.fileExists(atPath: m.source, isDirectory: &isDir) else { continue }
            // FSEvents reports real paths (/private/tmp), and Foundation's symlink resolution strips /private.
            guard let real = realpath(m.source, nil).map({ raw -> String in defer { free(raw) }; return String(cString: raw) }) else { continue }
            let dir = isDir.boolValue ? real : (real as NSString).deletingLastPathComponent
            found.append(Root(key: key, path: dir, only: isDir.boolValue ? nil : real))
        }
        guard !found.isEmpty else { return }
        queue.async { [self] in roots[containerID] = found; restream() }
    }

    /// The VM stopped: every share is gone.
    func removeAll() {
        queue.async { [self] in roots = [:]; seen = [:]; restream() }
    }

    func remove(containerID: String) {
        queue.async { [self] in
            guard roots.removeValue(forKey: containerID) != nil else { return }
            if roots.isEmpty { seen = [:] }
            restream()
        }
    }

    // MARK: stream lifetime (on queue)

    private func restream() {
        let paths = Array(Set(roots.values.joined().map(\.path))).sorted()
        if paths == streamPaths, stream != nil || paths.isEmpty { return }
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        streamPaths = paths
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<HostFileEvents>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(rawPaths, to: CFArray.self) as? [String] ?? []
            me.handle(list, Array(UnsafeBufferPointer(start: eventFlags, count: count)))
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.02, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    // MARK: events (on queue)

    /// True when `path` differs from the last time it was forwarded (or was never seen).
    private func changed(_ path: String) -> Bool {
        var st = stat()
        let now = lstat(path, &st) == 0
            ? Signature(sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec, size: st.st_size, ino: st.st_ino, exists: true)
            : Signature(sec: 0, nsec: 0, size: 0, ino: 0, exists: false)
        if seen[path] == now { return false }
        if seen.count >= Self.seenLimit { seen.removeAll(keepingCapacity: true) }
        seen[path] = now
        return true
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        var folders = Set<String>(), files = Set<String>()
        let all = roots.values.joined()
        for (path, flag) in zip(paths, flags) {
            let dropped = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                          | kFSEventStreamEventFlagKernelDropped) != 0
            guard dropped || flag & Self.flagMask != 0 else { continue }
            if !dropped, !changed(path) { continue }     // echo of our own poke (or a no-op touch)
            let isFile = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
            let structural = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                            | kFSEventStreamEventFlagItemRenamed) != 0
            for r in all where path == r.path || path.hasPrefix(r.path + "/") {
                if let only = r.only, path != only { continue }
                let rel = String(path.dropFirst(r.path.count).drop { $0 == "/" })
                let parent = rel.contains("/") ? (rel as NSString).deletingLastPathComponent : ""
                func guest(_ s: String) -> String { s.isEmpty ? r.key : r.key + "/" + s }
                if dropped { folders.insert(guest("")); continue }
                if r.only != nil { files.insert(guest(rel)); continue }
                if structural || !isFile { folders.insert(guest(parent)) }
                if isFile { files.insert(guest(rel)) }
            }
        }
        var out = Array(folders).sorted()
        if files.count <= Self.fileLimit { out += files.sorted() }
        guard !out.isEmpty else { return }
        for start in stride(from: 0, to: out.count, by: 256) { sink(Array(out[start..<min(start + 256, out.count)])) }
    }
}
