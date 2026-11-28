import Darwin
import Foundation

/// Optional host routing for Models. Connecting to the existing socket never launches noodled or its VM.
enum ModelNameRoute {
    /// A home-scoped opt-out also applies to CLI commands launched by the desktop app.
    static func isEnabled(in directory: URL) -> Bool {
        env["NOODLE_LOCAL_NAMES"] != "0" &&
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("direct-connection").path)
    }

    struct Lease: Codable {
        let token: String
        let daemon: ModelRunner.ProcessIdentity
        let baseURL: URL
    }

    private struct Registration: Decodable {
        let token: String
        let host: String
        /// The router's actual HTTP listener, including a fallback when port 80 is occupied.
        let port: Int
    }

    static func daemonIdentity() -> ModelRunner.ProcessIdentity? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes + [0])
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return ModelRunner.ProcessIdentity.read(pid)
    }

    static func register(_ session: ModelRunner.Session, daemon: ModelRunner.ProcessIdentity) -> Lease? {
        guard let process = session.process, process.isLive,
              let body = try? JSONSerialization.data(withJSONObject: [
                "host": "models.noodle.local", "port": session.port, "ownerPID": process.pid,
              ]),
              let data = try? DevCommand.request("POST", "/noodle/dev", body: body),
              let registration = try? JSONDecoder().decode(Registration.self, from: data),
              registration.host == "models.noodle.local", (1...65535).contains(registration.port),
              daemonIdentity() == daemon,
              let url = URL(string: "http://\(registration.host)\(registration.port == 80 ? "" : ":\(registration.port)")/v1") else {
            return nil
        }
        return Lease(token: registration.token, daemon: daemon, baseURL: url)
    }

    static func unregister(_ lease: Lease) {
        // A restarted daemon owns a different route table. Never send it a previous daemon's token.
        guard daemonIdentity() == lease.daemon else { return }
        _ = try? DevCommand.request("DELETE", "/noodle/dev/" + lease.token)
    }
}
