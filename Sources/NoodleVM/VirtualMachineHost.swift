import Foundation
import Virtualization
import NoodleCore
import os

/// One boot of one Virtualization.framework VM. Every VZ call runs on `queue`.
public final class VirtualMachineHost: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    public let queue = DispatchQueue(label: "app.noodle.vm", qos: .userInitiated)
    var vm: VZVirtualMachine?
    private var balloon: VZVirtioTraditionalMemoryBalloonDevice?
    var socketDevice: VZVirtioSocketDevice?
    var hostShares: [String: [String: HostShareTable.Entry]] = [:]
    /// Stopping the VM (idle sleep, shutdown) drops every retained share.
    var retainedShares = HostShareTable()
    /// A new VZSharedDirectory object is a new share to the guest and invalidates bind mounts already in use, so an
    /// object is replaced only when its key moves to the placeholder.
    var shareObjects: [String: (entry: HostShareTable.Entry, directory: VZSharedDirectory)] = [:]
    let config: VMBootConfiguration
    private let stopHandler: @Sendable (Error?) -> Void
    var consoleCapture: BootConsoleCapture?
    /// Guest-initiated ports and their handlers (SSH agent 1030, Mac loopback 1034). Kept across attempts and boots.
    var listenerHandlers: [UInt32: @Sendable (Int32) -> Void] = [:]
    var vsockListeners: [UInt32: (listener: VZVirtioSocketListener, delegate: GuestListenerDelegate)] = [:]
    var readyListener: VZVirtioSocketListener?
    let readyDelegate = GuestListenerDelegate()
    var announced = false
    var announceWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    public let configuredMemory: UInt64

    /// `onStop` fires once when the guest powers off or the VM errors.
    public init(configuration: VMBootConfiguration, onStop: @escaping @Sendable (Error?) -> Void) {
        config = configuration
        stopHandler = onStop
        configuredMemory = UInt64(configuration.memoryMiB) << 20
        super.init()
    }

    /// Build and validate the configuration without creating a VM (used by tests and diagnostics).
    public func validateConfiguration() throws {
        defer { closeConsole() }
        _ = try buildConfiguration()
    }

    public func start() async throws {
        try await StartRetry().run(record: { [self] attempt in
            let line = "noodle: VM start attempt \(attempt.number) failed after \(attempt.elapsedMs) ms, retrying: \(attempt.error)"
            Logger(subsystem: "app.noodle", category: "vm").error("\(line, privacy: .public)")
            appendConsole(line + "\n")
        }, body: { [self] in try await startOnce() })
    }

    private func appendConsole(_ text: String) {
        queue.async { [self] in
            guard config.captureBootConsole, let data = text.data(using: .utf8) else { return }
            if consoleCapture == nil {
                consoleCapture = try? BootConsoleCapture(url: config.consoleLog, queue: queue)
            }
            consoleCapture?.appendDiagnostic(data)
        }
    }

    private func startOnce() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // A failed earlier attempt leaves its VM object and console handle behind.
                release()
                do {
                    let configuration = try buildConfiguration()
                    let machine = VZVirtualMachine(configuration: configuration, queue: queue)
                    machine.delegate = self
                    vm = machine
                    balloon = machine.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
                    socketDevice = machine.socketDevices.first as? VZVirtioSocketDevice
                    applyGuestListeners()
                    listenForAnnounce()
                    machine.start { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let e):
                            self.release()
                            cont.resume(throwing: VMError.startFailed("\(e)"))
                        }
                    }
                } catch {
                    release()
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Ask the guest to power off through ACPI-style request (the agent also handles `shutdown` directly).
    public func requestStop() {
        queue.async { [self] in try? vm?.requestStop() }
    }

    /// Hard stop. Safe to call more than once.
    public func forceStop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard let machine = vm, machine.state != .stopped, machine.canStop else {
                    release(); cont.resume(); return
                }
                machine.stop { _ in
                    self.queue.async { self.release() }
                    cont.resume()
                }
            }
        }
    }

    private func release() {
        vm = nil; balloon = nil; socketDevice = nil; readyListener = nil
        let waiters = announceWaiters; announceWaiters = [:]
        for w in waiters.values { w.resume() }
        hostShares.removeAll()
        retainedShares.removeAll()
        shareObjects.removeAll()
        closeConsole()
    }

    private func closeConsole() {
        consoleCapture?.close()
        consoleCapture = nil
    }

    /// Set the memory the guest may keep. Clamped to [256 MiB, configured].
    public func setBalloonTarget(bytes: UInt64) {
        queue.async { [self] in
            guard let balloon else { return }
            let clamped = max(256 << 20, min(bytes, configuredMemory))
            balloon.targetVirtualMachineMemorySize = clamped
        }
    }

    // MARK: VZVirtualMachineDelegate
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        release()
        stopHandler(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        release()
        stopHandler(error)
    }
}
