import Foundation

private let agentPort: UInt32 = 1030

enum Host {
    nonisolated(unsafe) static var socketPath = ""
    static func finish(_ code: Int32) -> Never {
        unlink(socketPath)
        exit(code)
    }
}

/// Accept loop on its own thread: no event loop is involved, blocking calls are fine here.
func serve(machine: MachineVM, path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard fd >= 0, bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0, listen(fd, 16) == 0 else { fail("cannot listen on \(path)") }
    chmod(path, 0o600)
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EBADF { break }
                if errno != EINTR { usleep(100_000) } // EMFILE and friends: do not spin
                continue
            }
            machine.connect(port: agentPort) { guest in
                guard let guest else { close(client); return }
                bridge(client, guest)
            }
        }
    }
}

/// Copy both directions until either side ends, then close both.
private func bridge(_ a: Int32, _ b: Int32) {
    let done = DispatchGroup()
    for (from, to) in [(a, b), (b, a)] {
        done.enter()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            loop: while true {
                let n = read(from, &buf, buf.count)
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                    if w <= 0 { break loop }
                    off += w
                }
            }
            shutdown(a, SHUT_RDWR)
            shutdown(b, SHUT_RDWR)
            done.leave()
        }
    }
    // No third thread parked per connection: close both once the two copies end.
    done.notify(queue: .global()) { close(a); close(b) }
}
