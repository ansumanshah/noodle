import Foundation
import NoodleCore

extension ModelStore {
    private static let partialLifetime: TimeInterval = 7 * 24 * 3600

    private var partials: URL { scratch.appendingPathComponent(customWeights == nil ? "partial" : ".partial", isDirectory: true) }

    private static func size(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Drops partial downloads nobody has touched for a week.
    func removeStalePartials() {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.partialLifetime)
        let urls = (try? files.contentsOfDirectory(at: partials, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls where url.pathExtension == "part" {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? files.removeItem(at: url)
            }
        }
    }

    func download(_ url: String, to file: URL, sha256: String, totalBytes: UInt64 = 0,
                  report: (@Sendable (LocalModelPullProgress) -> Void)? = nil) throws {
        let files = FileManager.default
        try files.createDirectory(at: partials, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hex = sha256.hasPrefix("sha256:") ? String(sha256.dropFirst("sha256:".count)) : sha256
        let partial = partials.appendingPathComponent(hex + ".part")

        let progressQueue = report.map { _ in DispatchQueue(label: "dev.getnoodle.model-download", qos: .utility) }
        let meter = progressQueue.map { DispatchSource.makeTimerSource(queue: $0) }
        if let meter, let report {
            report(.init(phase: .downloading, receivedBytes: min(Self.size(of: partial), totalBytes), totalBytes: totalBytes))
            meter.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            meter.setEventHandler {
                report(.init(phase: .downloading, receivedBytes: min(Self.size(of: partial), totalBytes), totalBytes: totalBytes))
            }
            meter.resume()
        }
        var finished = false
        defer { if !finished { meter?.cancel() } }
        func stopMeter() {
            meter?.cancel()
            progressQueue?.sync {} // Drain any in-flight byte report before announcing verification.
            finished = true
        }

        let fd = open(partial.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw modelPOSIXError() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw CLIError("another pull is already downloading this file")
        }
        func fdSize() -> UInt64 {
            var info = stat()
            return fstat(fd, &info) == 0 ? UInt64(max(info.st_size, 0)) : 0
        }

        var stalls = 0
        var verify = false
        while !verify {
            switch DownloadResume.next(partialBytes: fdSize(), totalBytes: totalBytes) {
            case .restart:
                ftruncate(fd, 0)
            case .verify:
                verify = true
            case .fetch(let from):
                var args = [
                    "--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                    "--proto-redir", "=https", "--connect-timeout", "20", "--speed-limit", "1", "--speed-time", "60",
                ]
                if from > 0 { args += ["--continue-at", String(from)] }
                args += ["--output", "-", url]
                let result: (code: Int32, err: String)
                do { result = try withHuggingFaceAuth(for: url) { try streamCurl($0 + args, into: fd) } } catch { stopMeter(); throw error }
                let decision = DownloadResume.after(code: result.code, before: from, after: fdSize(), stalls: stalls)
                stalls = decision.stalls
                switch decision.outcome {
                case .done: verify = true
                case .retry(let seconds): Thread.sleep(forTimeInterval: seconds)
                case .restart: ftruncate(fd, 0)
                case .fail:
                    stopMeter()
                    throw CLIError("download failed. \(result.err)")
                }
            }
        }
        stopMeter()
        report?(.init(phase: .verifying, receivedBytes: totalBytes, totalBytes: totalBytes))
        fsync(fd)
        guard try Digest.sha256(file: partial) == sha256 else {
            ftruncate(fd, 0)
            try? files.removeItem(at: partial)
            throw CLIError("download checksum mismatch. The file was discarded.")
        }
        try? files.removeItem(at: file)
        try files.moveItem(at: partial, to: file)
    }

    /// Runs curl with its body on a pipe so noodle is the only writer. Returns curl's exit code and stderr.
    private func streamCurl(_ args: [String], into fd: Int32) throws -> (code: Int32, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.environment = env
        let out = Pipe(), errPipe = Pipe()
        process.standardOutput = out
        process.standardError = errPipe
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let errText = ErrorDrain(errPipe.fileHandleForReading)
        var failure: Error?
        while failure == nil {
            guard let chunk = try? out.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            do { try Self.writeAll(chunk, to: fd) } catch { failure = error }
        }
        if failure != nil { process.terminate() }
        process.waitUntilExit()
        let text = errText.wait()
        if let failure { throw failure }
        return (process.terminationStatus, text)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw modelPOSIXError()
                }
                offset += n
            }
        }
    }
}

/// Reads a pipe to the end on a background queue so curl never blocks on a full stderr buffer.
private final class ErrorDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let bytes = handle.readDataToEndOfFile()
            self.data = bytes
            self.group.leave()
        }
    }

    func wait() -> String {
        group.wait()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
