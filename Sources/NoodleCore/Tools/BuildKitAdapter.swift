import Foundation

/// This pin is sealed into the app's on-demand.json, rather than fetched from the release server.
public struct BuildKitAdapterPin: Codable, Sendable, Equatable {
    public let version: String
    public let url: URL
    public let size: Int64
    public let sha256: String

    public static func decode(_ data: Data) throws -> Self {
        struct Manifest: Decodable { let buildkit: BuildKitAdapterPin }
        let pin = try JSONDecoder().decode(Manifest.self, from: data).buildkit
        guard !pin.version.isEmpty, pin.size > 0, pin.sha256.count == 64, Digest.isValid(pin.sha256),
              UpdateClient.isAllowedTransport(pin.url), pin.url.user == nil, pin.url.password == nil else {
            throw BuildKitAdapterError("invalid BuildKit manifest")
        }
        return pin
    }

    public func verify(_ archive: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value
        guard size == self.size else { throw BuildKitAdapterError("BuildKit size mismatch; expected \(self.size) bytes") }
        guard try Digest.sha256(file: archive) == "sha256:" + sha256 else {
            throw BuildKitAdapterError("BuildKit SHA-256 mismatch")
        }
    }
}

public struct BuildKitAdapterError: LocalizedError, CustomStringConvertible {
    public let description: String
    public var errorDescription: String? { description }
    init(_ message: String) { description = message }
}

/// Shared by the daemon's native builder and the CLI's explicit tools prefetch.
/// Blocking methods must run on a worker queue, never a NIO event loop.
public struct BuildKitAdapter: Sendable {
    /// User-facing tool name; `name` is the executable inside the archive.
    public static let toolName = "buildkit"
    public static let name = "noodle-buildkit-adapter"
    private static let licenses = "BuildKitAdapter-Licenses.txt"
    private let paths: NoodlePaths
    private let development: URL?
    private let contents: URL?
    // Injectable only within the module's tests; production always uses system curl.
    var curlExecutable = URL(fileURLWithPath: "/usr/bin/curl")
    var downloadKey: String { [paths.root.path, development?.path ?? "", contents?.path ?? "", paths.resourcesDirectory?.path ?? ""].joined(separator: "\n") }

    public init(paths: NoodlePaths, environment: [String: String] = ProcessInfo.processInfo.environment,
                executableURL: URL? = Bundle.main.executableURL) {
        self.paths = paths
        development = environment["NOODLE_RESOURCES"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        contents = executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var manifest: URL? {
        [development, paths.resourcesDirectory, contents?.appendingPathComponent("Resources")]
            .compactMap { $0?.appendingPathComponent("on-demand.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var configured: Bool { localExecutable != nil || manifest != nil }

    private var localExecutable: URL? {
        [development?.appendingPathComponent(Self.name), contents?.appendingPathComponent("Helpers/" + Self.name)]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func pin() throws -> BuildKitAdapterPin {
        guard let manifest else {
            throw BuildKitAdapterError("BuildKit support is missing; reinstall Noodle")
        }
        return try BuildKitAdapterPin.decode(Data(contentsOf: manifest))
    }

    private var directory: URL { Tools.directory(paths).appendingPathComponent(Self.toolName, isDirectory: true) }
    private func installation(_ pin: BuildKitAdapterPin) -> URL { directory.appendingPathComponent(pin.sha256, isDirectory: true) }

    private struct Receipt: Codable {
        let executable: String
        let licenses: String
    }

    private func cached(_ pin: BuildKitAdapterPin) -> URL? {
        let dir = installation(pin)
        let bin = dir.appendingPathComponent(Self.name)
        do {
            try pin.verify(dir.appendingPathComponent("archive.tar.gz"))
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: dir.appendingPathComponent("receipt.json")))
            guard FileManager.default.isExecutableFile(atPath: bin.path),
                  try Digest.sha256(file: bin) == receipt.executable,
                  try Digest.sha256(file: dir.appendingPathComponent(Self.licenses)) == receipt.licenses else { return nil }
            return bin
        } catch { return nil }
    }

    /// Development resources first, legacy bundled helper second, verified downloaded copy last.
    public func executable() throws -> URL? {
        if let localExecutable { return localExecutable }
        return try cached(pin())
    }

    public func install(progress: (String) -> Void = { _ in }) throws -> URL {
        try install(progress: progress, cancellation: AdapterCancellation())
    }

    fileprivate func install(progress: (String) -> Void = { _ in }, cancellation: AdapterCancellation) throws -> URL {
        try cancellation.check()
        if let localExecutable { return localExecutable }
        let pin = try pin()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Serialize daemon and CLI installs. Process death releases this advisory lock.
        let fd = open(directory.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR || errno == EWOULDBLOCK else { throw POSIXError(.EIO) }
            try cancellation.pause()
        }
        try cancellation.check()
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(".download-") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        if let cached = cached(pin) { return cached }
        let stage = directory.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        progress("Downloading BuildKit \(pin.version) from \(pin.url.absoluteString)\n")
        do {
            let archive = stage.appendingPathComponent("archive.tar.gz")
            try download(pin, to: archive, cancellation: cancellation)
            try cancellation.check()
            try pin.verify(archive)
            try Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path, Self.name, Self.licenses], cancellation: cancellation)
            try cancellation.check()
            let bin = stage.appendingPathComponent(Self.name)
            let licenses = stage.appendingPathComponent(Self.licenses)
            for file in [bin, licenses] {
                let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
                guard type == .typeRegular else { throw BuildKitAdapterError("BuildKit archive must contain regular files") }
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            let receipt = Receipt(executable: try Digest.sha256(file: bin), licenses: try Digest.sha256(file: licenses))
            try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
            try cancellation.check()
            let final = installation(pin)
            // Replace a corrupt installation as a unit, including its archive and notices.
            let result = fm.fileExists(atPath: final.path)
                ? renamex_np(stage.path, final.path, UInt32(RENAME_SWAP)) : rename(stage.path, final.path)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return final.appendingPathComponent(Self.name)
        } catch {
            if error is CancellationError { throw error }
            throw BuildKitAdapterError("Cannot download BuildKit support from \(pin.url.absoluteString): \(error.localizedDescription). Check the connection and build again, or run noodle tools install \(Self.toolName).")
        }
    }

    private func download(_ pin: BuildKitAdapterPin, to archive: URL, cancellation: AdapterCancellation) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = curlExecutable
        // Stream decoded response bytes, including chunked HTTP bodies, through a bounded writer.
        process.arguments = ["--fail", "--silent", "--show-error", "--location",
            "--proto", "=https,http,file", "--proto-redir", "=https", "--connect-timeout", "15",
            "--max-time", "180", pin.url.absoluteString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard FileManager.default.createFile(atPath: archive.path, contents: nil) else { throw POSIXError(.EIO) }
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }
        try cancellation.start(process)
        defer { cancellation.stop(process); process.waitUntilExit() }
        var written: Int64 = 0
        while let data = try pipe.fileHandleForReading.read(upToCount: Int(max(1, min(64 * 1024, pin.size - written)))), !data.isEmpty {
            try cancellation.check()
            guard Int64(data.count) <= pin.size - written else {
                throw BuildKitAdapterError("BuildKit exceeds its pinned size of \(pin.size) bytes")
            }
            try output.write(contentsOf: data)
            written += Int64(data.count)
        }
        process.waitUntilExit()
        try cancellation.check()
        guard process.terminationStatus == 0 else { throw BuildKitAdapterError("download failed (curl exit \(process.terminationStatus))") }
    }

    private static func run(_ executable: String, _ arguments: [String], cancellation: AdapterCancellation) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        try cancellation.start(process)
        defer { cancellation.stop(process); process.waitUntilExit() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try cancellation.check()
        guard process.terminationStatus == 0 else {
            throw BuildKitAdapterError(String(decoding: data.prefix(2048), as: UTF8.self))
        }
    }
}

/// All state and subprocess launch/termination are protected by the condition.
fileprivate final class AdapterCancellation: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var process: Process?

    func check() throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw CancellationError() }
    }

    func pause() throws {
        condition.lock(); defer { condition.unlock() }
        if !cancelled { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05)) }
        if cancelled { throw CancellationError() }
    }

    func start(_ process: Process) throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func stop(_ process: Process) {
        condition.lock(); defer { condition.unlock() }
        if process.isRunning { process.terminate() }
        if self.process === process { self.process = nil }
    }

    func cancel() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        condition.broadcast()
    }
}

/// One in-flight install per resource/home combination. Cancelled callers leave promptly;
/// only the last waiter cancels the subprocess. Empty entries are removed, with no idle timer.
public actor BuildKitAdapterDownloads {
    public static let shared = BuildKitAdapterDownloads()
    private struct Flight {
        let id = UUID()
        let cancellation = AdapterCancellation()
        var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    }
    private var flights: [String: Flight] = [:]
    var waiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
    public init() {}

    public func install(_ adapter: BuildKitAdapter) async throws -> URL {
        try Task.checkCancellation()
        let key = adapter.downloadKey, waiter = UUID()
        let binary: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if flights[key] != nil { flights[key]?.waiters[waiter] = continuation; return }
                var flight = Flight()
                flight.waiters[waiter] = continuation
                flights[key] = flight
                let id = flight.id, cancellation = flight.cancellation
                DispatchQueue.global(qos: .utility).async {
                    let result = Result { try adapter.install(cancellation: cancellation) }
                    Task { await self.finish(key, id: id, result: result) }
                }
            }
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
        try Task.checkCancellation()
        return binary
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: waiter) else { return }
        if flights[key]?.waiters.isEmpty == true {
            flights.removeValue(forKey: key)?.cancellation.cancel()
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: String, id: UUID, result: Result<URL, Error>) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        for continuation in flight.waiters.values { continuation.resume(with: result) }
    }
}
