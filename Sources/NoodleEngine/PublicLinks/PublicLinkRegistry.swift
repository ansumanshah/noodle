import Foundation
import NoodleCore

/// A registry avoids adding stored state to Engine. No process, timer or listener exists before use.
final class PublicLinkRegistry: @unchecked Sendable {
    static let shared = PublicLinkRegistry()
    struct Entry {
        weak var owner: Engine?
        var manager: PublicLinkManager?
        var closing = false
    }
    let lock = NSLock()
    var entries: [ObjectIdentifier: Entry] = [:]
    func manager(_ engine: Engine, create: Bool) -> PublicLinkManager? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(engine)
        var entry = entries[key].flatMap { $0.owner === engine ? $0 : nil } ?? Entry(owner: engine)
        guard !create || !entry.closing else { return nil }
        if let manager = entry.manager { return manager }
        guard create else { return nil }
        let manager = PublicLinkManager(paths: engine.paths)
        entry.manager = manager
        entries[key] = entry
        return manager
    }

    /// Gate registration before taking the shutdown snapshot, including when no manager exists yet.
    func close(_ engine: Engine) -> PublicLinkManager? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(engine)
        var entry = entries[key].flatMap { $0.owner === engine ? $0 : nil } ?? Entry(owner: engine)
        entry.closing = true
        entries[key] = entry
        return entry.manager
    }
}
