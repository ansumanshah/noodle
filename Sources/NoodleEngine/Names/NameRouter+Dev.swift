import Foundation
import NoodleCore

extension NameRouter {
    func update(_ table: [LocalNames.Target], openers: [String: Opener]) {
        lock.withLock {
            guard !stopped else { return }
            let live = table.filter { !$0.containerID.hasPrefix("dev:") || devRoutes[String($0.containerID.dropFirst(4))] != nil }
            targets = Dictionary(live.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })
            self.openers = openers
            dns.update(hosts: Set(targets.keys))
        }
    }

    /// No polling: kqueue observes each owner only while it owns a route. Request paths also prune dead owners.
    func addDev(host: String, port: Int, ownerPID: Int32) throws -> String {
        let token = UUID().uuidString.lowercased()
        let source = DispatchSource.makeProcessSource(identifier: ownerPID, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.removeDev(token) }
        lock.lock()
        guard !stopped, !devRoutes.values.contains(where: { $0.host == host }), targets[host] == nil else {
            lock.unlock(); source.resume(); source.cancel()
            throw EngineError.conflict("Local name \(host) is already in use. Choose another name.")
        }
        devRoutes[token] = DevRoute(token: token, host: host, port: port, ownerPID: ownerPID, exit: source)
        source.resume()
        lock.unlock()
        // Cover an exit between the API's validation and kqueue registration.
        guard Self.ownerAlive(ownerPID) else {
            removeDev(token)
            throw EngineError.badRequest("The dev route owner has exited.")
        }
        return token
    }

    func removeDev(_ token: String) {
        let removed = lock.withLock {
            let removed = devRoutes.removeValue(forKey: token)
            if let removed {
                targets[removed.host] = nil
                dns.update(hosts: Set(targets.keys))
            }
            return removed
        }
        if let removed { removed.exit.cancel(); onDevChange() }
    }

    static func ownerAlive(_ pid: Int32) -> Bool { pid > 1 && (kill(pid, 0) == 0 || errno == EPERM) }

    func devTargets() -> [LocalNames.Target] {
        pruneOwners()
        return lock.withLock {
            devRoutes.values.map {
                LocalNames.Target(host: $0.host, containerID: "dev:" + $0.token, ip: "127.0.0.1", port: $0.port, kind: "host")
            }
        }
    }

    func pruneOwners() {
        let dead = lock.withLock { devRoutes.values.filter { !Self.ownerAlive($0.ownerPID) }.map(\.token) }
        for token in dead { removeDev(token) }
    }
}
