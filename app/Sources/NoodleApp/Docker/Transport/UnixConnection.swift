import Foundation
import Network

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class UnixConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "noodle.app.http", qos: .userInitiated)
    private var eof = false

    init(path: String) {
        conn = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { [conn] state in
                switch state {
                case .ready:
                    if once.fire() { c.resume() }
                case .failed(let e), .waiting(let e):
                    if once.fire() { c.resume(throwing: TransportError.unreachable(e.localizedDescription)) }
                    conn.cancel()
                case .cancelled:
                    if once.fire() { c.resume(throwing: CancellationError()) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    /// Returns nil at end of stream.
    func receive() async throws -> Data? {
        if eof { return nil }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    if isComplete { eof = true }
                    c.resume(returning: data)
                } else if let error {
                    if case .posix(let code) = error, code == .ECONNRESET || code == .ENOTCONN { eof = true; c.resume(returning: nil) }
                    else { c.resume(throwing: error) }
                } else {
                    eof = true
                    c.resume(returning: nil)
                }
            }
        }
    }

    func close() { conn.cancel() }
}
