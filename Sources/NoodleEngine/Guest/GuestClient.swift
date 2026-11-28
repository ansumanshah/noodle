import Foundation
import OSLog
import NoodleCore
import NoodleVM

/// Host side of the guest agent protocol: one persistent control connection plus one connection per stream.
public actor GuestClient {
    private let vm: VMController
    private let log = Logger(subsystem: "app.noodle", category: "guest")
    private var channel: FDChannel?
    private var readerTask: Task<Void, Never>?
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private var samplingUsage = false
    private var connecting: Task<Void, Error>?
    private var eventHandler: (@Sendable (GuestEvent) -> Void)?
    private var streamCount = 0
    private var streamHandler: (@Sendable (Int) -> Void)?

    public init(vm: VMController) { self.vm = vm }

    public func setEventHandler(_ h: @escaping @Sendable (GuestEvent) -> Void) { eventHandler = h }

    /// Called with the number of open streams whenever it changes.
    public func setStreamCountHandler(_ h: @escaping @Sendable (Int) -> Void) { streamHandler = h }

    public var isConnected: Bool { channel != nil }

    // MARK: control

    private func ensureConnected() async throws {
        if channel != nil { return }
        if let t = connecting { try await t.value; return }
        let t = Task { [self] in
            let fd = try await vm.connect(port: NoodleWire.controlPort)
            adopt(fd)
        }
        connecting = t
        defer { connecting = nil }
        try await t.value
    }

    private func adopt(_ fd: Int32) {
        let ch = FDChannel(fd: fd, label: "app.noodle.control")
        channel = ch
        readerTask = Task { [weak self] in
            var decoder = ControlFrameDecoder()
            do {
                while let d = try await ch.read() {
                    decoder.append(d)
                    while let payload = try decoder.next() { await self?.handle(payload) }
                }
                await self?.connectionLost(ch)
            } catch {
                await self?.connectionLost(ch)
            }
        }
    }

    private func handle(_ payload: Data) {
        do {
            switch try GuestMessage.parse(payload) {
            case .response(let id, let result):
                guard let cont = pending.removeValue(forKey: id) else { return }
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            case .event(let ev):
                eventHandler?(ev)
            }
        } catch {
            log.error("bad control frame: \(String(describing: error))")
        }
    }

    private func connectionLost(_ ch: FDChannel) {
        guard channel === ch else { return }
        channel = nil
        ch.close()
        let waiting = pending; pending = [:]
        for (_, c) in waiting { c.resume(throwing: GuestError("Linux connection lost")) }
    }

    /// Drop the control connection (VM stopped).
    public func disconnect() {
        readerTask?.cancel(); readerTask = nil
        if let ch = channel { connectionLost(ch) }
    }

    /// `activity: false` leaves the idle and reclaim clocks alone, for the controller's own housekeeping calls.
    @discardableResult
    public func call(
        _ op: String, _ args: [String: JSONValue] = [:], boot: Bool = true, activity: Bool = true
    ) async throws -> [String: JSONValue] {
        if boot { try await vm.ensureRunning() }
        if activity { await vm.noteActivity() }
        // Non-booting operations (especially shutdown) only use an existing control
        // connection. Reconnecting while .stopping would wait, then boot a new VM.
        if boot { try await ensureConnected() }
        guard let ch = channel else { throw GuestError("Linux connection is not ready") }
        let id = nextID; nextID += 1
        let frame = try GuestRequest(id: id, op: op, args: args).encodedFrame()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: JSONValue], Error>) in
            pending[id] = cont
            if ch.writeNow(frame) { return }
            Task {
                do { try await ch.write(frame) }
                catch {
                    if let c = self.takePending(id) { c.resume(throwing: GuestError("write failed: \(error)")) }
                }
            }
        }
    }

    private func takePending(_ id: UInt64) -> CheckedContinuation<[String: JSONValue], Error>? { pending.removeValue(forKey: id) }

    /// A status read must leave sleep and reclaim deadlines alone. Skip it when the wire is busy.
    func sampleUsage() async throws -> [String: JSONValue]? {
        guard !samplingUsage, let ch = channel else { return nil }
        let id = nextID; nextID += 1
        let frame = try GuestRequest(id: id, op: GuestOp.vmUsage).encodedFrame()
        guard ch.writeNow(frame) else { return nil }
        samplingUsage = true
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            takePending(id)?.resume(throwing: GuestError("VM usage sample timed out"))
        }
        defer { deadline.cancel(); samplingUsage = false }
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    public func call<T: Decodable>(_ op: String, _ args: [String: JSONValue] = [:], as type: T.Type) async throws -> T {
        let r = try await call(op, args)
        return try JSONValue.object(r).decode()
    }

    // MARK: streams

    /// Open a stream: connect to the stream port, send the op, wait for the `{"ok":true}` acknowledgement.
    /// A burst of new streams can overflow the guest's accept queue. Nothing has reached the guest yet, so retrying is safe.
    private func connectStream() async throws -> Int32 {
        for delay in [2, 4, 8, 16, 32, 64] {
            do { return try await vm.connect(port: NoodleWire.streamPort) } catch VMError.connectFailed {
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
        return try await vm.connect(port: NoodleWire.streamPort)
    }

    public func openStream(_ op: String, _ args: [String: JSONValue] = [:]) async throws -> GuestStream {
        try Task.checkCancellation()
        try await vm.ensureRunning()
        await vm.noteActivity()
        let fd = try await connectStream()
        let ch = FDChannel(fd: fd, label: "app.noodle.stream")
        streamCount += 1
        streamHandler?(streamCount)
        let counter = StreamCounter(client: self)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                var req = args
                req["op"] = .string(op)
                try await ch.write(LengthPrefixed.encode(JSONEncoder().encode(JSONValue.object(req))))
                var decoder = ControlFrameDecoder()
                var ack: Data?
                while ack == nil {
                    guard let d = try await ch.read() else { throw GuestError("stream closed during handshake") }
                    decoder.append(d)
                    ack = try decoder.next()
                }
                let v = try JSONDecoder().decode(JSONValue.self, from: ack!)
                if v["ok"]?.bool != true {
                    throw GuestError(v["error"]?.string ?? "stream refused", errno: Int32(truncatingIfNeeded: v["errno"]?.int ?? 0))
                }
                let leftover = decoder.takeRemainder()
                try Task.checkCancellation()
                return GuestStream(channel: ch, leftover: leftover, onClose: { counter.release() })
            } onCancel: { ch.close() }
        } catch {
            ch.close()
            counter.release()
            throw error
        }
    }

    fileprivate func streamClosed() { streamCount = max(0, streamCount - 1); streamHandler?(streamCount) }
}

/// Decrements the stream counter exactly once, from any thread.
final class StreamCounter: @unchecked Sendable {
    private let client: GuestClient
    private let lock = NSLock()
    private var released = false
    init(client: GuestClient) { self.client = client }
    func release() {
        lock.lock(); let r = released; released = true; lock.unlock()
        if !r { Task { await client.streamClosed() } }
    }
}
