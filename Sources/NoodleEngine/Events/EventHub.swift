import Foundation
import NoodleCore
import NoodleImages

// MARK: events

final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<EventMessage>.Continuation] = [:]
    private var history: [EventMessage] = []
    private static let capacity = 512
    /// Unread events a subscriber may hold; a consumer further behind than this is disconnected.
    static let subscriberBuffer = 1024

    func publish(_ e: EventMessage) {
        lock.lock()
        history.append(e)
        if history.count > Self.capacity { history.removeFirst(history.count - Self.capacity) }
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { if case .dropped = s.yield(e) { s.finish() } }
    }

    func snapshot(since: Int64?, until: Int64?) -> [EventMessage] {
        lock.lock(); defer { lock.unlock() }
        return history.filter { e in (since.map { e.time >= $0 } ?? true) && (until.map { e.time <= $0 } ?? true) }
    }

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscribers.count }

    func subscribe() -> AsyncStream<EventMessage> {
        let id = UUID()
        let (stream, cont) = AsyncStream<EventMessage>.makeStream(bufferingPolicy: .bufferingNewest(Self.subscriberBuffer))
        lock.lock(); subscribers[id] = cont; lock.unlock()
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
        }
        return stream
    }
}
