import Darwin
import Foundation
import NoodleAPI
import NoodleCore
import NoodleEngine

/// Headless daemon: Docker API on a unix socket, VM booted lazily by the engine. Links no AppKit or SwiftUI.
@main
struct NoodleDaemon {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--version") { print("noodled 26.11.7"); return }
        if args.contains("--help") || args.contains("-h") {
            print("usage: noodled [--socket PATH]\nenv: NOODLE_HOME (default ~/.noodle), NOODLE_CPUS, NOODLE_MEMORY_MIB")
            return
        }
        Self.reexecWithOneMallocMagazine()
        signal(SIGPIPE, SIG_IGN)
        let paths = NoodlePaths.resolve()
        do { try paths.ensureDirectories() } catch { fail("cannot create \(paths.root.path): \(error)") }
        chmod(paths.runDir.path, 0o700)

        var socket = paths.socket.path
        if let i = args.firstIndex(of: "--socket"), let v = args.dropFirst(args.distance(from: args.startIndex, to: i) + 1).first { socket = v }
        guard let lock = acquireLock(paths.runDir.appendingPathComponent("noodled.lock").path) else {
            fail("another noodled is already running (lock \(paths.runDir.path)/noodled.lock)")
        }
        _ = lock   // held for the life of the process

        let engine = Engine(paths: paths)
        do { try await engine.start() } catch { fail("engine start failed: \(error)") }
        let server = DockerServer(engine: engine, socketPath: socket, guestSocketPath: paths.guestSocket.path, threads: 1)
        do { try await server.start() } catch { fail("cannot listen on \(socket): \(error)") }
        FileHandle.standardError.write(Data("noodled: listening on \(socket)\n".utf8))

        await waitForTermination()
        FileHandle.standardError.write(Data("noodled: shutting down\n".utf8))
        // A wedged guest must not keep the daemon, its lock and its socket alive. State is flushed before the VM stops.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("noodled: shutdown did not finish in 20 s, exiting\n".utf8))
            exit(1)
        }
        await server.stopAccepting()
        await engine.shutdown()
        await server.stop()
        exit(0)
    }

    /// libmalloc reads its tuning from the environment at process start. One magazine instead of one per core keeps the
    /// daemon's small-allocation regions few and dense (measured -0.6 MB fresh): the daemon is I/O bound with a handful
    /// of threads, so there is no allocator contention to lose. MallocSpaceEfficient trades allocator speed for density
    /// and returns freed pages sooner (asleep 6.4 -> 5.2 MB, VM awake 12 -> 4.7 MB, measured with `footprint`).
    /// Same pid, one extra exec of a few ms at launch.
    static func reexecWithOneMallocMagazine() {
        guard getenv("MallocMaxMagazines") == nil else { return }
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        setenv("MallocMaxMagazines", "1", 1)
        setenv("MallocSpaceEfficient", "1", 1)
        execv(buffer, CommandLine.unsafeArgv)
        unsetenv("MallocMaxMagazines"); unsetenv("MallocSpaceEfficient")   // exec failed: carry on with the default allocator
    }

    /// Single-instance lock: flock on a file in the run directory, released by the kernel on exit.
    static func acquireLock(_ path: String) -> Int32? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        return fd
    }

    static func waitForTermination() async {
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "noodled.signals")
            let once = OnceBox(c)
            for sig in [SIGTERM, SIGINT] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
                src.setEventHandler { once.fire() }
                src.resume()
                Retained.sources.append(src)
            }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("noodled: \(message)\n".utf8))
        exit(1)
    }
}

final class OnceBox: @unchecked Sendable {
    private var c: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Void, Never>) { self.c = c }
    func fire() { lock.lock(); let x = c; c = nil; lock.unlock(); x?.resume() }
}

enum Retained { nonisolated(unsafe) static var sources: [DispatchSourceSignal] = [] }
