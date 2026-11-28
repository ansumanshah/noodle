import Foundation

// Client side of the machine agent protocol: frames of
// `type u8, length u32 BE, payload` over the unix socket of a running machine's helper.

private enum Kind {
    static let request: UInt8 = 1, input: UInt8 = 2, output: UInt8 = 3, errput: UInt8 = 4
    static let eof: UInt8 = 5, winch: UInt8 = 6, signal: UInt8 = 7, exit: UInt8 = 8
}

private func frame(_ kind: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let n = UInt32(payload.count)
    return [kind, UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] + payload
}

private func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return false }
        off += n
    }
    return true
}

func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 { close(fd); return nil }
    return fd
}

struct MachineRequest {
    var tty = false
    var rows = 24, cols = 80
    var cwd: String?
    var user = "root"
    var env: [String] = []
    var args: [String] = []
    var poweroff = false

    var payload: [UInt8] {
        var items = ["T\(tty ? 1 : 0)", "R\(rows)", "C\(cols)", "U\(user)"]
        if let cwd { items.append("D" + cwd) }
        if poweroff { items.append("P") }
        items += env.map { "E" + $0 } + args.map { "A" + $0 }
        return items.flatMap { Array($0.utf8) + [0] }
    }
}

/// Serializes writes from the input thread and the signal handlers onto one connection.
private final class Link: @unchecked Sendable {
    let fd: Int32
    let lock = NSLock()
    init(fd: Int32) { self.fd = fd }
    func send(_ kind: UInt8, _ payload: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        _ = writeFully(fd, frame(kind, payload))
    }
}

private func windowSize() -> (rows: Int, cols: Int) {
    var ws = winsize()
    if ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_row > 0 { return (Int(ws.ws_row), Int(ws.ws_col)) }
    return (24, 80)
}

/// Run one session. `forwardInput` pipes this process's stdin in; `tty` also puts the terminal in raw mode and
/// follows its size. Output goes to stdout/stderr, or to `capture` when given. Returns the exit status of the
/// remote process, or nil when the connection could not be made or dropped before one arrived.
func runMachineSession(socket path: String, request: MachineRequest, forwardInput: Bool, capture: (@Sendable ([UInt8]) -> Void)? = nil) -> Int32? {
    guard let fd = connectUnix(path) else { return nil }
    let link = Link(fd: fd)
    var request = request
    if request.tty { (request.rows, request.cols) = windowSize() }
    link.send(Kind.request, request.payload)

    var saved = termios()
    let rawMode = request.tty && tcgetattr(0, &saved) == 0
    if rawMode {
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
    }
    defer { if rawMode { tcsetattr(0, TCSANOW, &saved) } }

    var sources: [DispatchSourceSignal] = []
    func watch(_ sig: Int32, _ action: @escaping @Sendable () -> Void) {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        s.setEventHandler(handler: action)
        s.resume()
        sources.append(s)
    }
    for sig in [SIGINT, SIGTERM, SIGHUP] { watch(sig) { link.send(Kind.signal, [UInt8(sig)]) } }
    if request.tty {
        watch(SIGWINCH) {
            let (r, c) = windowSize()
            link.send(Kind.winch, [UInt8(r >> 8), UInt8(r & 255), UInt8(c >> 8), UInt8(c & 255)])
        }
    }
    let tty = request.tty
    if forwardInput {
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(0, &buf, buf.count)
                if n <= 0 { if !tty { link.send(Kind.eof, []) }; return }
                link.send(Kind.input, Array(buf[0..<n]))
            }
        }
    }

    var pending: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { close(fd); return nil }
        pending += chunk[0..<n]
        while pending.count >= 5 {
            let len = Int(pending[1]) << 24 | Int(pending[2]) << 16 | Int(pending[3]) << 8 | Int(pending[4])
            if pending.count < 5 + len { break }
            let kind = pending[0]
            let body = Array(pending[5..<(5 + len)])
            pending.removeFirst(5 + len)
            switch kind {
            case Kind.output: if let capture { capture(body) } else { _ = writeFully(1, body) }
            case Kind.errput: if let capture { capture(body) } else { _ = writeFully(2, body) }
            case Kind.exit where body.count == 4:
                close(fd)
                return Int32(bitPattern: UInt32(body[0]) << 24 | UInt32(body[1]) << 16 | UInt32(body[2]) << 8 | UInt32(body[3]))
            default: break
            }
        }
    }
}
