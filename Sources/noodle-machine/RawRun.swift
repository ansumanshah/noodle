import Foundation
import CryptoKit

typealias RawJSON = [String: Any]
func rawError(_ message: String) -> MachineError { .message(message) }

/// Standalone workload VM. No daemon state, host shares, or persistent guest disk.
func rawRun(_ arguments: [String]) -> Never {
    var options: [String: String] = [:]
    var remaining = arguments
    while let key = remaining.first, key != "--" {
        remaining.removeFirst()
        guard key.hasPrefix("--"), let value = remaining.first else { fail("raw-run: expected --option value") }
        remaining.removeFirst(); options[String(key.dropFirst(2))] = value
    }
    guard remaining.first == "--" else { fail("raw-run: expected -- before rootfs or local image") }
    remaining.removeFirst()
    guard let source = remaining.first else { fail("raw-run: missing rootfs or local image") }
    remaining.removeFirst()
    for key in ["home", "resources", "kernel", "initramfs"] where options[key] == nil { fail("raw-run: missing --\(key)") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-raw-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { fail("raw-run: \(error)") }
    let session = RawSession(directory: temporary)
    signal(SIGPIPE, SIG_IGN)
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number in
        let signalSource = DispatchSource.makeSignalSource(signal: number, queue: .main)
        signalSource.setEventHandler { session.finish(128 + number) }; signalSource.resume(); return signalSource
    }
    let capturedOptions = options
    let capturedCommand = remaining
    Thread.detachNewThread {
        do { try session.prepare(options: capturedOptions, source: source, command: capturedCommand) }
        catch { FileHandle.standardError.write(Data("noodle-machine: raw-run: \(error)\n".utf8)); session.finish(1) }
    }
    withExtendedLifetime(signals) { dispatchMain() }
}

final class RawSession: @unchecked Sendable {
    let directory: URL
    var machine: MachineVM?
    private var activeProcess: Process?
    let finishLock = NSLock()
    var finished = false
    init(directory: URL) { self.directory = directory }

    func finish(_ code: Int32) {
        finishLock.lock()
        if finished { finishLock.unlock(); return }
        finished = true
        let runningMachine = machine
        let child = activeProcess
        finishLock.unlock()
        Thread.detachNewThread { [self] in
            let stopped = DispatchSemaphore(value: 0)
            if let child, child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
            runningMachine?.forceStop { stopped.signal() }
            if runningMachine != nil { _ = stopped.wait(timeout: .now() + 5) }
            try? FileManager.default.removeItem(at: directory)
            exit(code)
        }
    }

    func process(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) throws {
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        p.environment = environment; p.standardOutput = FileHandle.standardError
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        // Publish only a successfully launched child, atomically with cancellation.
        finishLock.lock()
        guard !finished else { finishLock.unlock(); throw rawError("raw-run cancelled") }
        do { try p.run(); activeProcess = p; finishLock.unlock() }
        catch { finishLock.unlock(); throw error }
        defer {
            finishLock.lock()
            if activeProcess === p { activeProcess = nil }
            finishLock.unlock()
        }
        if p.isRunning, done.wait(timeout: .now() + 1800) == .timedOut {  // tar and mke2fs on a big rootfs run long
            p.terminate(); kill(p.processIdentifier, SIGKILL); p.waitUntilExit()
            throw rawError("\(executable.lastPathComponent) timed out")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw rawError("\(executable.lastPathComponent) failed (\(p.terminationStatus))") }
    }

    func connect(_ port: UInt32, timeout: Double = 10) throws -> RawWire {
        let result = RawConnectionResult()
        finishLock.lock()
        let runningMachine = finished ? nil : machine
        finishLock.unlock()
        guard let runningMachine else { throw rawError("raw-run cancelled") }
        runningMachine.connect(port: port) { fd in result.complete(fd) }
        guard let fd = result.wait(timeout) else { throw rawError("guest connection timed out or failed (port \(port))") }
        return RawWire(fd, timeout: Int(timeout))
    }
    func size(_ url: URL) throws -> Int64 { (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
    func validDigest(_ s: String) -> Bool { s.hasPrefix("sha256:") && s.count == 71 && s.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) } }
    func hash(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var h = SHA256()
        while let chunk = try f.read(upToCount: 1024 * 1024), !chunk.isEmpty { h.update(data: chunk) }
        return "sha256:" + h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
