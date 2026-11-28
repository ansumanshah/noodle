import Foundation
import Observation
import NoodleCore

/// Keeps the models current. Window visible: event stream. Window closed: nothing runs; the menu bar reads
/// data when its menu opens.
@MainActor @Observable
final class SyncController {
    private unowned let env: AppEnvironment
    private var eventTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var dirty: Set<String> = []
    private var readinessRevision = 0
    private var usageTask: Task<Void, Never>?
    private var initialRefresh: Task<Void, Never>?
    private(set) var windowVisible = false

    init(env: AppEnvironment) { self.env = env }

    func setWindowVisible(_ visible: Bool) {
        let visible = visible && !env.nav.uninstallRunning && !env.nav.uninstallFinished
        if !env.demo { env.macMachine.setWindowVisible(visible) }
        guard visible != windowVisible || (visible && eventTask == nil) else { return }
        windowVisible = visible
        eventTask?.cancel(); eventTask = nil
        if visible {
            env.reloadVMSettings()
            eventTask = Task { await self.eventLoop() }
            Task { await refreshDockerTarget() }
        } else {
            debounce?.cancel(); debounce = nil
            usageTask?.cancel(); usageTask = nil
            readinessRevision += 1
            // A window covered during launch still needs its first snapshot. After that,
            // an occluded window has no event stream or recurring usage samples.
            if case .connecting = env.connection.phase, initialRefresh == nil {
                initialRefresh = Task {
                    await refreshNow()
                    initialRefresh = nil
                }
            }
        }
    }

    func refreshNow() async {
        async let dockerTarget: Void = refreshDockerTarget()
        do { try await refreshAll(); markUp() } catch { markDown(error) }
        await dockerTarget
        if env.nav.route == .machines {
            if env.nav.machinePlatform == .linux {
                env.machines.configure(demo: env.demo)
                await env.machines.reload(selected: env.nav.selectedMachine)
            } else if !env.demo {
                env.macMachine.reload()
            }
        }
    }

    func refreshWorkspace() async {
        env.reloadVMSettings()
        await refreshNow()
        NotificationCenter.default.post(name: .overviewRefresh, object: nil)
    }

    func retryConnection() async {
        let connection = env.connection
        guard case .down = connection.phase, connection.transition == nil, !connection.retryingConnection else { return }
        connection.retryingConnection = true
        defer { connection.retryingConnection = false }
        await refreshNow()
    }

    private func markUp() {
        env.connection.reconnecting = false
        if env.connection.phase != .up { env.connection.phase = .up }
    }
    private func markDown(_ error: Error) {
        if env.connection.isUp && env.connection.transition == nil { env.connection.reconnecting = true }
        readinessRevision += 1
        env.connection.vmReadiness = nil
        env.connection.vmCPUPercent = nil
        usageTask?.cancel(); usageTask = nil
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Motion.animate { env.connection.phase = .down(text) }
    }

    private func refreshAll() async throws {
        let svc = env.service
        try await svc.ping()
        async let readiness: Void = refreshVMReadiness()
        async let info = svc.info()
        try await env.containers.refresh()
        try? await env.images.refresh()
        try? await env.volumes.refresh()
        try? await env.networks.refresh()
        env.connection.info = try? await info
        await readiness
    }

    func refreshVMReadiness() async {
        readinessRevision += 1
        let revision = readinessRevision
        let status = try? await env.service.vmStatus()
        guard !Task.isCancelled, revision == readinessRevision else { return }
        let connection = env.connection
        if let status, let boot = status.bootCount, boot == connection.vmReadiness?.bootCount,
           let current = status.usage, let previous = connection.vmReadiness?.usage {
            connection.vmCPUPercent = current.percent(since: previous)
        } else {
            connection.vmCPUPercent = nil
        }
        connection.vmReadiness = status
        updateUsagePolling()
    }

    private func updateUsagePolling() {
        guard windowVisible, !env.demo, let status = env.connection.vmReadiness, status.state != "stopped" else {
            usageTask?.cancel(); usageTask = nil
            return
        }
        guard usageTask == nil else { return }
        usageTask = Task {
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(for: .seconds(2), tolerance: .milliseconds(400)) }
                catch { return }
                await refreshVMReadiness()
            }
        }
    }

    func refreshDockerTarget() async {
        if env.demo {
            env.connection.dockerTarget = "Noodle"
            return
        }
        let socket = env.paths.socket.path
        let (target, missing) = await Task.detached {
            (SetupProbe.dockerTarget(noodleSocket: socket),
             !SetupProbe.dockerContexts(ProcessInfo.processInfo.environment).endpoints.contains { $0.name == "noodle" })
        }.value
        if env.connection.dockerTarget != target { env.connection.dockerTarget = target }
        let show = missing && !env.demo
        let elsewhere = target != "Noodle" && !env.demo
        if env.connection.dockerElsewhere != elsewhere { env.connection.dockerElsewhere = elsewhere }
        if env.connection.noodleContextMissing != show { env.connection.noodleContextMissing = show }
    }

    private func eventLoop() async {
        var backoff = 1.0
        while !Task.isCancelled {
            do {
                try await refreshAll()
                try Task.checkCancellation()
                markUp()
                let stream = try await env.service.events()
                backoff = 1
                for try await e in stream { note(e) }
                try Task.checkCancellation()
                markDown(TransportError.closed)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                markDown(error)
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
    }

    private func note(_ e: DockerEvent) {
        if !env.demo { env.firstStart.observe(e) }
        dirty.insert(e.type)
        guard debounce == nil else { return }
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let kinds = dirty; dirty = []; debounce = nil
            if kinds.contains("container") { try? await env.containers.refresh() }
            if kinds.contains("image") { try? await env.images.refresh() }
            if kinds.contains("volume") { try? await env.volumes.refresh() }
            if kinds.contains("network") { try? await env.networks.refresh() }
            if kinds.contains("container") {
                async let readiness: Void = refreshVMReadiness()
                env.connection.info = try? await env.service.info()
                await readiness
            } else if !kinds.isEmpty && usageTask == nil {
                await refreshVMReadiness()
            }
        }
    }
}
