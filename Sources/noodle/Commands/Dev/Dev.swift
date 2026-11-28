import Foundation
import Darwin

/// Runs only for the lifetime of an explicitly launched development command.
func cmdDev(_ args: [String]) {
    if args == ["--help"] || args == ["-h"] {
        out(CommandTable.groupHelp("dev"))
        return
    }
    do { exit(try DevCommand.run(args)) }
    catch { die(error) }
}

enum DevCommand {
    struct Registration: Decodable, Sendable {
        let token: String
        let host: String
        let httpsPort: Int
        let ca: String
    }

    static func run(_ args: [String]) throws -> Int32 {
        var command = args
        var explicitName: String?
        if let separator = args.firstIndex(of: "--"), separator <= 1 {
            if separator == 1 { explicitName = args[0] }
            command = Array(args.dropFirst(separator + 1))
        } else if let first = args.first, executable(first) == nil {
            explicitName = first
            command = Array(args.dropFirst())
        }
        guard let first = command.first, let program = executable(first) else {
            throw CLIError("usage: noodle dev [name] [--] <command> [arguments...] (command must be executable)", exitCode: ExitCode.usage)
        }
        let host = try inferredHost(explicitName)
        let (reservation, port) = try reservePort()
        var reserved = true
        defer { if reserved { close(reservation) } }

        let child = DevChild()
        let watchedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
        let oldHandlers = watchedSignals.map { Darwin.signal($0, SIG_IGN) }
        let sources = watchedSignals.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { child.forward(number) }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            for (number, handler) in zip(watchedSignals, oldHandlers) { _ = Darwin.signal(number, handler) }
        }

        let body = try JSONSerialization.data(withJSONObject: ["host": host, "port": port, "ownerPID": getpid()])
        let registration = try JSONDecoder().decode(Registration.self, from: request("POST", "/noodle/dev", body: body))
        defer { _ = try? request("DELETE", "/noodle/dev/" + registration.token) }
        child.registered { _ = try? request("DELETE", "/noodle/dev/" + registration.token) }
        if let signal = child.receivedSignal { return 128 + signal }

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(port)
        environment["HOST"] = "127.0.0.1"
        var attributes: posix_spawnattr_t?
        let initStatus = posix_spawnattr_init(&attributes)
        guard initStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: initStatus) ?? .EINVAL) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for number in watchedSignals { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var arguments = command.map { strdup($0) } + [nil]
        var variables = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for argument in arguments { free(argument) }
            for variable in variables { free(variable) }
        }
        // Keep the OS-assigned port reserved through registration. Release immediately before the child binds it.
        close(reservation); reserved = false
        var pid: pid_t = 0
        let status = posix_spawn(&pid, program, nil, &attributes, &arguments, &variables)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .ENOENT) }
        child.started(pid)

        // Interactive commands inherit the terminal as well as stdio. Ignore SIGTTOU only while changing its owner.
        let previousGroup = tcgetpgrp(STDIN_FILENO)
        let ownsTerminal = previousGroup == getpgrp()
        if ownsTerminal { setForegroundGroup(pid) }
        defer {
            child.finished()
            if ownsTerminal { setForegroundGroup(previousGroup) }
        }
        let url = "https://\(registration.host)\(registration.httpsPort == 443 ? "" : ":\(registration.httpsPort)")\n"
        FileHandle.standardOutput.write(Data(url.utf8))
        var result: Int32 = 0
        while waitpid(pid, &result, 0) < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }
        // Darwin's wait status macros are unavailable to Swift.
        let terminatingSignal = result & 0x7f
        return terminatingSignal == 0 ? (result >> 8) & 0xff : 128 + terminatingSignal
    }

    private static func setForegroundGroup(_ group: pid_t) {
        let old = Darwin.signal(SIGTTOU, SIG_IGN)
        _ = tcsetpgrp(STDIN_FILENO, group)
        _ = Darwin.signal(SIGTTOU, old)
    }

    private static func executable(_ name: String) -> String? {
        if name.contains("/") {
            let path = URL(fileURLWithPath: name).standardizedFileURL.path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return which(name)
    }

    private static func reservePort() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard bound == 0, inspected == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

}

private final class DevChild: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var firstSignal: Int32?
    private var unregister: (@Sendable () -> Void)?
    var receivedSignal: Int32? { lock.withLock { firstSignal } }
    func registered(_ unregister: @escaping @Sendable () -> Void) {
        let signaled = lock.withLock { self.unregister = unregister; return firstSignal != nil }
        if signaled { unregister() }
    }
    func started(_ pid: pid_t) {
        lock.withLock {
            self.pid = pid
            if let firstSignal { _ = kill(-pid, firstSignal) }
        }
    }
    func finished() { lock.withLock { pid = 0; unregister = nil } }
    func forward(_ number: Int32) {
        let cleanup = lock.withLock {
            if firstSignal == nil { firstSignal = number }
            if pid > 0 { _ = kill(-pid, number) }
            return unregister
        }
        cleanup?()
    }
}
