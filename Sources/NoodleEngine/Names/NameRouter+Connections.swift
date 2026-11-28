import Foundation
import NoodleCore

extension NameRouter {
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let t = tasks; tasks = [:]
        let c = clients; clients = [:]
        let owners = devRoutes; devRoutes = [:]
        lock.unlock()
        dns.stop()
        http.stop(); https?.stop()
        for (_, route) in owners { route.exit.cancel() }
        for (_, client) in c { client.close() }
        for (_, task) in t { task.cancel() }
    }

    private func hasName(_ host: String) -> Bool {
        pruneOwners()
        return lock.withLock {
            guard let target = targets[host] else { return false }
            return !target.containerID.hasPrefix("dev:") || devRoutes[String(target.containerID.dropFirst(4))] != nil
        }
    }

    func accept(_ c: Int32, tls: Bool) {
        if tls {
            TLSSession.start(fd: c, identities: identities, allowed: { [weak self] in self?.hasName($0) ?? false }) { [weak self] plain in
                if let self { self.route(plain) } else { Darwin.close(plain) }
            }
        } else {
            route(c)
        }
    }

    private func route(_ fd: Int32) {
        let client = FDChannel(fd: fd, label: "app.noodle.names.client")
        let id = UUID()
        lock.lock()
        if stopped { lock.unlock(); client.close(); return }
        clients[id] = client
        tasks[id] = Task { [weak self] in
            await self?.serve(client)
            self?.finish(id)
        }
        lock.unlock()
    }

    private func finish(_ id: UUID) { lock.lock(); tasks[id] = nil; clients[id] = nil; lock.unlock() }

    func lookup(_ host: String) -> (LocalNames.Target, Opener?)? {
        pruneOwners()
        lock.lock(); defer { lock.unlock() }
        guard let t = targets[host] else { return nil }
        if t.containerID.hasPrefix("host:") { return (t, nil) }
        if t.containerID.hasPrefix("dev:") {
            guard devRoutes[String(t.containerID.dropFirst(4))] != nil else { return nil }
            return (t, nil)
        }
        guard let opener = openers[t.containerID] else { return nil }
        return (t, opener)
    }

    func names() -> [String] { lock.lock(); defer { lock.unlock() }; return targets.keys.sorted() }
}
