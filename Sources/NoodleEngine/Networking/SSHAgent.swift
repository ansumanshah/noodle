import Foundation
import NoodleCore

/// SSH agent forwarding, on demand. A container that bind-mounts `/run/host-services/ssh-auth.sock` makes the engine
/// register one vsock listener; the guest agent relays each connection on its own socket here, and this connects it to
/// the Mac's agent. Only the agent protocol crosses; no key material is copied anywhere. Nothing listens until used.
enum SSHAgent {
    static let hostSource = "/run/host-services/ssh-auth.sock"
    static let vsockPort = NoodleWire.sshAgentPort

    /// Where the Mac's agent socket is: `$NOODLE_HOME/ssh-auth-sock` (one path), `NOODLE_SSH_AUTH_SOCK`, `SSH_AUTH_SOCK`,
    /// then launchd's value (the login agent a launch-agent daemon cannot see in its own environment).
    static func agentPath(paths: NoodlePaths, env: [String: String] = ProcessInfo.processInfo.environment,
                          launchd: () -> String? = launchdValue) -> String? {
        if let s = try? String(contentsOf: paths.root.appendingPathComponent("ssh-auth-sock"), encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        for k in ["NOODLE_SSH_AUTH_SOCK", "SSH_AUTH_SOCK"] { if let v = env[k], !v.isEmpty { return v } }
        return launchd()
    }

    static func launchdValue() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !t.isEmpty ? t : nil
    }

    static func connectUnix(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { for (i, b) in bytes.enumerated() { $0[i] = b }; $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if rc != 0 { Darwin.close(fd); return nil }
        return fd
    }

    /// Relays open at once, per kind: a container opening thousands of connections must not exhaust noodled's
    /// descriptors, and long Docker API streams (logs -f, events) must not starve the SSH agent.
    static let maxRelays = 64
    private enum Kind: Int { case agent, docker
        var label: String { self == .agent ? "ssh" : "docker" }
    }
    private static let state = NSLock()
    nonisolated(unsafe) private static var open = [0, 0]
    nonisolated(unsafe) private static var cachedPath: String?
    /// Connecting and resolving block (launchctl, unix connect), so they never run on the VM's serial queue.
    private static let connectQueue = DispatchQueue(label: "app.noodle.ssh.connect", attributes: .concurrent)

    /// The cached agent path is tried first; a failed connect re-resolves it once (the agent may have restarted).
    static func connectAgent(paths: NoodlePaths) -> Int32? {
        state.lock(); let cached = cachedPath; state.unlock()
        if let cached, let fd = connectUnix(cached) { return fd }
        guard let path = agentPath(paths: paths), let fd = connectUnix(path) else { return nil }
        state.lock(); cachedPath = path; state.unlock()
        return fd
    }

    /// A guest connection arrived: join it to the Mac's agent, or close it when there is none or the cap is reached.
    static func serve(guestFD: Int32, paths: NoodlePaths) {
        serve(guestFD: guestFD, kind: .agent) { connectAgent(paths: paths) }
    }

    /// A guest connection arrived on the Docker API relay: join it to noodled's guest socket (Docker API only).
    static func serveDockerAPI(guestFD: Int32, paths: NoodlePaths) {
        serve(guestFD: guestFD, kind: .docker) { connectUnix(paths.guestSocket.path) }
    }

    private static func serve(guestFD: Int32, kind: Kind, connect: @escaping @Sendable () -> Int32?) {
        state.lock()
        guard open[kind.rawValue] < maxRelays else { state.unlock(); Darwin.close(guestFD); return }
        open[kind.rawValue] += 1
        state.unlock()
        connectQueue.async {
            guard let agent = connect() else { release(kind); Darwin.close(guestFD); return }
            let a = FDChannel(fd: guestFD, label: "app.noodle.\(kind.label).guest")
            let b = FDChannel(fd: agent, label: "app.noodle.\(kind.label).peer")
            Task {
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { await pump(a, b) }
                    g.addTask { await pump(b, a) }
                }
                a.close(); b.close()
                release(kind)
            }
        }
    }

    private static func release(_ kind: Kind) { state.lock(); open[kind.rawValue] -= 1; state.unlock() }

    static func pump(_ from: FDChannel, _ to: FDChannel) async {
        do { while let d = try await from.read() { try await to.write(d) } } catch {}
        to.shutdownWrite()
    }
}
