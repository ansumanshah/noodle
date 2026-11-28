import Foundation

/// One serial background writer. A write in flight leaves at most one newer pending snapshot.
final class ModelChatWriter: @unchecked Sendable {
    private let file: URL
    private let queue = DispatchQueue(label: "noodle.model-chat-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: Data?
    private var scheduled = false
    private let finished: @Sendable (Bool) -> Void

    init(file: URL, finished: @escaping @Sendable (Bool) -> Void) {
        self.file = file
        self.finished = finished
    }

    func enqueue(_ data: Data) {
        lock.lock()
        pending = data
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func flush() { queue.sync { drain() } }

    private func drain() {
        while true {
            lock.lock()
            guard let data = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            finished((try? ModelChatPersistence.write(data, to: file)) != nil)
        }
    }
}
