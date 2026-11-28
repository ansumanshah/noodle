import Foundation
import NoodleCore

extension PublicLinkManager {
    func consume(_ id: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id], entry.status.state == "starting" else { return }
        entry.buffer.append(data)
        // The supervisor prints a line naming the helper it spawned, so the daemon can kill it if the supervisor dies alone.
        // Accepted once, and only for a direct child of the supervisor, so a spoofed line cannot aim a signal elsewhere.
        let marker = Data("noodle-link-helper-pid=".utf8)
        if entry.helperPID == nil, let r = entry.buffer.range(of: marker),
           r.lowerBound == entry.buffer.startIndex || entry.buffer[r.lowerBound - 1] == 10,
           let nl = entry.buffer[r.upperBound...].firstIndex(of: 10) {
            // Only a direct child of this link's supervisor counts; its start time pins the identity against PID reuse.
            if let pid = Int32(String(decoding: entry.buffer[r.upperBound..<nl], as: UTF8.self)), pid > 1,
               let info = Self.processInfo(pid), Int32(info.pbi_ppid) == entry.status.pid {
                entry.helperPID = pid; entry.helperStart = Self.startTime(info)
            }
            entry.buffer.removeSubrange(r.lowerBound...nl)
        }
        // Never persist helper output: it may contain origin metadata. Retain at most 8 KiB for URL discovery.
        if entry.buffer.count > 8192 { entry.buffer = Data(entry.buffer.suffix(8192)) }
        let text = String(decoding: entry.buffer, as: UTF8.self)
        if let url = Self.tunnelURL(in: text) {
            entry.status.url = url; entry.status.state = "running"; entry.buffer.removeAll()
        }
        entries[id] = entry
        try? saveLocked()
    }

    /// Only the quick tunnel banner counts, and `api.trycloudflare.com` is Cloudflare's own endpoint, which appears in errors.
    static func tunnelURL(in text: String) -> String? {
        guard let banner = text.range(of: "Your quick Tunnel has been created") else { return nil }
        let rest = String(text[banner.upperBound...])
        var from = rest.startIndex
        while let range = rest.range(of: #"https://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com(?=[\s/|]|$)"#, options: .regularExpression, range: from..<rest.endIndex) {
            let url = String(rest[range])
            if url != "https://api.trycloudflare.com" { return url }
            from = range.upperBound
        }
        return nil
    }

    func exited(_ id: String, code: Int32) {
        lock.lock()
        guard let entry = entries[id] else { lock.unlock(); return }
        if entry.status.state == "starting" || entry.status.state == "running" {
            entries[id]?.status.state = "failed"
            entries[id]?.status.detail = "cloudflared exited (status \(code)); run noodle link again to publish"
        }
        entries[id]?.status.pid = nil
        entries[id]?.process = nil; entries[id]?.control = nil; entries[id]?.output = nil
        entries[id]?.listener = nil; entries[id]?.directory = nil; entries[id]?.helperPID = nil
        try? saveLocked()
        lock.unlock()
        // The relay stays bound, refusing connections, until the helper is confirmed dead: a helper that outlived its
        // supervisor would otherwise keep a public URL pointing at a port another Mac service could bind.
        entry.listener?.quiesce()
        let helper = entry.helperPID, start = entry.helperStart, listener = entry.listener
        Task.detached { await Self.reapHelper(pid: helper, start: start); listener?.stop() }
        entry.output?.fileHandleForReading.readabilityHandler = nil
        try? entry.control?.fileHandleForWriting.close()
        if let directory = entry.directory { try? FileManager.default.removeItem(at: directory) }
    }

    func stop(_ id: String, reason: String) {
        lock.lock()
        guard let entry = entries[id], entry.status.state == "running" || entry.status.state == "starting" else { lock.unlock(); return }
        entries[id]?.status.state = "stopped"; entries[id]?.status.detail = reason
        try? saveLocked()
        lock.unlock()
        // Refuse traffic now but keep the port bound; `exited` releases it once the helper is dead.
        entry.listener?.quiesce()
        try? entry.control?.fileHandleForWriting.close()
        if entry.process?.isRunning != true { exited(id, code: 1) }
    }
    static func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
    static func startTime(_ info: proc_bsdinfo) -> UInt64 { info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec }

    /// Kill a helper that may have outlived its supervisor. The PID is signalled only while it is still the same process
    /// (same start time) that the supervisor reported as its child.
    static func reapHelper(pid: Int32?, start: UInt64?) async {
        guard let pid, pid > 1, let start else { return }
        func alive() -> Bool {
            guard let info = processInfo(pid), startTime(info) == start else { return false }
            return info.pbi_status != UInt32(SZOMB)
        }
        guard alive() else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where alive() { try? await Task.sleep(for: .milliseconds(50)) }
        if alive() { kill(pid, SIGKILL) }
        for _ in 0..<40 where alive() { try? await Task.sleep(for: .milliseconds(50)) }
    }
    func stopAll(reason: String) { for status in all() { stop(status.id, reason: reason) } }
    func stopContainer(_ id: String) { for status in all() where status.containerID == id { stop(status.id, reason: "container stopped; link was not restored") } }

    /// Called only from detached work, after signalling all children to stop together.
    func waitForExit(_ ids: [String]) {
        for id in ids {
            lock.lock()
            let process = entries[id]?.process
            lock.unlock()
            process?.waitUntilExit()
        }
    }
}
