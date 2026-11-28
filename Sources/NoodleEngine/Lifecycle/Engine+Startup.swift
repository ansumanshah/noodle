import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

extension Engine {
    // MARK: lifecycle

    /// Load state and wire up the VM hooks. Does not boot the VM unless a restart-policy container needs it.
    public func start() async throws {
        guard !started else { return }
        shuttingDown = false
        // A vm.json that does not decode could hold "host_loopback": false. Refuse to start rather than guess.
        try VMSettings.validateFile(paths: paths)
        try paths.ensureDirectories()
        try loadState()
        try await imageStore.validateCatalog()
        started = true
        ensureBuiltinNetworks()
        await startHostLoopback()
        // The VM died with the previous daemon: nothing is running.
        let now = Date()
        for var c in containers.values where c.isRunningLike {
            c.status = .exited; c.exitCode = 255; c.pid = 0; c.finishedAt = now
            c.error = ""
            for k in c.endpoints.keys { c.endpoints[k]?.ip = ""; c.endpoints[k]?.ip6 = nil }
            c.ports = [:]
            containers[c.id] = c
        }
        let me = self
        for rt in runtimes {
            var hooks = VMHooks()
            hooks.shutdownGuest = { [guest = rt.guest] in _ = try? await guest.call(GuestOp.shutdown, boot: false) }
            hooks.balloonHint = { [guest = rt.guest] in
                guard await guest.isConnected,
                      let r = try? await guest.call(GuestOp.balloonHint, boot: false, activity: false) else { return (nil, nil) }
                return (r["cache"]?.int.flatMap { UInt64(exactly: $0) }, r["used"]?.int.flatMap { UInt64(exactly: $0) })
            }
            hooks.cpuTicks = { [guest = rt.guest] in
                guard await guest.isConnected, let r = try? await guest.sampleUsage(),
                      let busy = r["cpu_busy"]?.int.flatMap({ UInt64(exactly: $0) }),
                      let total = r["cpu_total"]?.int.flatMap({ UInt64(exactly: $0) }) else { return nil }
                return (busy, total)
            }
            hooks.didStop = { await me.vmDidStop(rt) }
            await rt.vm.setHooks(hooks)
            // One drain task per stream delivers events and counts in arrival order; shutdown() finishes both.
            let (events, eventFeed) = AsyncStream.makeStream(of: GuestEvent.self)
            let (counts, countFeed) = AsyncStream.makeStream(of: Int.self)
            rt.closeFeeds = { eventFeed.finish(); countFeed.finish() }
            Task { for await ev in events { await me.guestEvent(ev, from: rt) } }
            Task { for await n in counts { await me.streamCountChanged(rt, n) } }
            await rt.guest.setEventHandler { ev in
                if case .dnsQuery(let id, let query) = ev {
                    Task { await HostDNS.reply(to: query, id: id, through: rt.guest) }
                } else {
                    eventFeed.yield(ev)
                }
            }
            await rt.guest.setStreamCountHandler { n in countFeed.yield(n) }
        }
        await imageStore.blobs.clearTemp()
        imageStore.blobs.sweepPartials(olderThan: 7 * 24 * 3600)
        if proxy != ProxySettings() { await imageStore.registry.setProxy(proxy) }
        flushState()

        for c in containers.values where shouldRestartAtLaunch(c) {
            let id = c.id
            restartTasks[id] = Task { [weak self] in
                try? await self?.startContainer(id)
                await self?.clearRestartTask(id)
            }
        }
    }

    private func shouldRestartAtLaunch(_ c: ContainerRecord) -> Bool {
        guard !c.stoppedByUser else { return false }
        switch c.hostConfig.RestartPolicy.Name {
        case "always", "unless-stopped": return true
        default: return false
        }
    }

    func clearRestartTask(_ id: String) { restartTasks[id] = nil }

    /// Stop listeners, flush state, sleep the VM. Called on daemon exit.
    public func shutdown() async {
        cancelAllWaiters()
        await shutdownPublicLinks()
        await stopNativeBuilder()
        guard started else { return }
        shuttingDown = true
        for t in restartTasks.values { t.cancel() }
        restartTasks = [:]
        for id in Array(healthTasks.keys) { stopHealth(id) }
        for ls in listeners.values { for l in ls { l.stop() } }
        listeners = [:]
        nameRouter?.stop(); nameRouter = nil
        flushState()
        for rt in runtimes { await rt.vm.shutdown() }
        for rt in runtimes { rt.closeFeeds?(); rt.closeFeeds = nil }
        flushState()
        started = false
    }
}
