import Foundation
import OSLog
import NoodleCore

/// Owns the VM lifecycle: lazy cold boot, sleep after idle, wake on demand, balloon reclaim.
/// Timers: exactly one pending `Task.sleep` with tolerance while the VM runs, none while it is stopped.
public actor VMController {
    let log = Logger(subsystem: "app.noodle", category: "vm")
    public let paths: NoodlePaths
    public let role: VMRole
    public private(set) var settings: VMSettings
    public private(set) var state: VMState = .stopped
    public private(set) var lastBootDuration: Duration?
    public private(set) var bootCount = 0

    var host: VirtualMachineHost?
    var hooks = VMHooks()
    private var startTask: Task<Void, Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var timer: ReusableTimer?
    var timerIsBusy = false
    var busy = false
    var lastActivity = ContinuousClock.now
    var balloonInflated = false
    /// Activity since the last reclaim: a reclaim is owed once the VM has been quiet for `reclaimQuiet`.
    var reclaimDue = false
    /// The last reclaim found cache to drop, so one more look is worth it. Otherwise nothing is armed until new activity.
    var reclaimWorked = false
    static let reclaimQuiet = Duration.seconds(20)
    static let reclaimMinCache: UInt64 = 32 << 20
    /// When the second look is due, if the last reclaim found cache.
    var secondLookAt: ContinuousClock.Instant?
    /// A busy guest postponed the reclaim until then.
    var reclaimNotBefore = ContinuousClock.now
    /// Checks in a row that found the guest idle while the balloon is inflated; after the first, the wait is 60 s.
    var quietChecks = 0
    /// Containers working without API calls (a build, a CI job) hold this much of the guest CPU or more: 5% of all CPUs.
    static let busyCPUShare: UInt64 = 20
    static let busyRecheck = Duration.seconds(30)
    static let inflatedCheckMax = Duration.seconds(60)
    private(set) var bootEpoch = 0
    private(set) var coldBootAttempts = 0
    /// Test seam: runs at the start of a cold boot, to hold the boot open while callers pile up.
    var bootGate: (@Sendable () async -> Void)?
    func setBootGate(_ gate: @escaping @Sendable () async -> Void) { bootGate = gate }
    private var machineStarted = false

    public var readiness: (state: VMState, vmRunning: Bool) {
        (state, machineStarted)
    }
    public var usageConfiguration: (boot: Int, cpus: Int, memoryMiB: Int)? {
        guard state == .running, let host else { return nil }
        return (bootCount, host.config.cpus, host.config.memoryMiB)
    }
    private var guestListeners: [UInt32: @Sendable (Int32) -> Void] = [:]

    public init(paths: NoodlePaths, settings: VMSettings, role: VMRole = .main) {
        self.paths = paths
        self.settings = settings
        self.role = role
    }

    public func setHooks(_ hooks: VMHooks) { self.hooks = hooks }

    public func setHostShares(containerID: String, mounts: [GuestMount]) async throws -> [GuestMount] {
        guard state == .running, let host else { throw VMError.notRunning }
        guard host.config.shareHostFolders else { throw VMError.invalidConfiguration("the privileged containers VM has no Mac folders") }
        return try await host.setHostShares(containerID: containerID, mounts: mounts)
    }

    public func removeHostShares(containerID: String) async {
        await host?.removeHostShares(containerID: containerID)
    }

    /// Accept guest-initiated vsock connections on `port` (the handler owns the fd). Nothing listens until this is
    /// called; it re-applies on every boot. One handler per port. Main VM only.
    public func setGuestListener(port: UInt32, handler: @escaping @Sendable (Int32) -> Void) {
        guard role == .main else { return }
        guestListeners[port] = handler
        host?.setGuestListener(port: port, handler: handler)
    }

    public func updateSettings(_ new: VMSettings) { settings = new }

    private func transition(_ s: VMState) {
        guard state != s else { return }
        state = s
    }

    // MARK: start / stop

    /// Boot the VM if needed and wait until the agent accepts vsock connections.
    public func ensureRunning() async throws {
        lastActivity = .now
        switch state {
        case .running:
            if balloonInflated { deflateBalloon() }
            return
        case .starting:
            if let t = startTask { try await t.value }
            return
        case .stopping:
            await waitUntilStopped()
            try await ensureRunning()
        case .stopped:
            // Set before any suspension so concurrent callers see .starting and share this task.
            transition(.starting)
            let task = Task { try await self.coldBoot() }
            startTask = task
            do { try await task.value } catch { startTask = nil; throw error }
            startTask = nil
        }
    }

    private func waitUntilStopped(epoch: Int? = nil) async {
        if state == .stopped || (epoch != nil && epoch != bootEpoch) { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func coldBoot() async throws {
        coldBootAttempts += 1
        transition(.starting)
        await bootGate?()
        let t0 = ContinuousClock.now
        do {
            try paths.ensureDirectories()
            let boot = VMBootConfiguration(paths: paths, settings: settings, role: role)
            try FileManager.default.createDirectory(at: boot.dataDisk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.prepareDataDisk(boot.dataDisk, sizeBytes: UInt64(settings.diskGiB) << 30)
            bootEpoch += 1
            let epoch = bootEpoch
            let machine = VirtualMachineHost(configuration: boot) { [weak self] error in
                Task { await self?.vmStopped(epoch: epoch, error: error) }
            }
            host = machine
            for (port, handler) in guestListeners { machine.setGuestListener(port: port, handler: handler) }
            try await machine.start()
            machineStarted = host === machine
            log.info("VM started, waiting for the guest agent")
            await machine.waitForAnnounce(timeout: .milliseconds(100))
            // Wait for the agent: the control port starts accepting once /init finished.
            try await waitForAgent(machine)
            transition(.running)
            let d = ContinuousClock.now - t0
            lastBootDuration = d
            bootCount += 1
            log.info("VM cold boot \(d.totalMilliseconds) ms (agent ready)")
            await hooks.didBoot()
            armTimer()
        } catch {
            if let h = host { await h.forceStop() }
            host = nil
            machineStarted = false
            transition(.stopped)
            log.error("VM boot failed: \(String(describing: error))")
            throw error
        }
    }

    private func waitForAgent(_ machine: VirtualMachineHost) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        // The agent announces itself on the ready port, so this returns as soon as its listeners exist. The periodic
        // retry only matters when that connection never arrives.
        var lastError: Error = VMError.notRunning
        while ContinuousClock.now < deadline {
            do {
                let fd = try await machine.connect(port: NoodleWire.controlPort)
                close(fd)
                return
            } catch {
                lastError = error
                await machine.waitForAnnounce(timeout: .milliseconds(100))
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        throw VMError.startFailed("Linux connection did not answer on vsock \(NoodleWire.controlPort): \(lastError). Check \(role == .main ? paths.vmLog.path : paths.workloadVMLog.path), including any data disk mount failure.")
    }

    private func vmStopped(epoch: Int, error: Error?) async {
        guard epoch == bootEpoch else { return }
        if let error { log.error("VM stopped with error: \(String(describing: error))") }
        disarmTimer()
        host = nil
        machineStarted = false
        balloonInflated = false
        secondLookAt = nil; quietChecks = 0; reclaimNotBefore = .now
        transition(.stopped)
        await hooks.didStop()
        let waiters = stopWaiters; stopWaiters = []
        for w in waiters { w.resume() }
    }

    /// Open a vsock connection (booting the VM first when it sleeps). Returns an owned fd.
    public func connect(port: UInt32) async throws -> Int32 {
        try await ensureRunning()
        lastActivity = .now
        guard let host else { throw VMError.notRunning }
        return try await host.connect(port: port)
    }

    /// Sleep now: guest `shutdown`, wait for power off, force stop after 5 s.
    public func sleepNow() async {
        guard state == .running, let machine = host else { return }
        transition(.stopping)
        disarmTimer()
        let epoch = bootEpoch
        await VMShutdown.run(timeout: .seconds(5), request: { [self] in
            await hooks.shutdownGuest()
            machine.requestStop()
        }, wait: { [self] in
            await waitUntilStopped(epoch: epoch)
        }, force: { [self] in
            await forceShutdown(machine, epoch: epoch)
        })
    }

    /// Sleep like the idle timer does, but now. Refuses while containers or long operations keep the VM busy.
    public func sleepIfIdle() async -> Bool {
        guard state == .running, !busy else { return false }
        await sleepNow()
        return true
    }

    private func forceShutdown(_ machine: VirtualMachineHost, epoch: Int) async {
        guard epoch == bootEpoch, host === machine, state != .stopped else { return }
        log.notice("guest did not power off in time, forcing stop")
        await machine.forceStop()
        await vmStopped(epoch: epoch, error: nil)
    }

    /// Daemon exit: stop the VM, do not wait for a graceful guest shutdown longer than needed.
    public func shutdown() async {
        if let t = startTask { _ = try? await t.value }
        await sleepNow()
    }

    public var isRunning: Bool { state == .running }
}
