import Foundation
import OSLog
import NoodleCore

/// Hooks the engine installs so the controller can talk to the guest agent without owning the connection.
public struct VMHooks: Sendable {
    /// Ask the agent to sync and power off (op `shutdown`). Errors are ignored; the controller force-stops after a timeout.
    public var shutdownGuest: @Sendable () async -> Void = {}
    /// Ask the agent to sync and drop caches (op `balloon_hint`) without marking the VM active. `cache` is the file cache
    /// it held, `used` what the guest uses after the drop (balloon pages excluded); each nil when unknown.
    public var balloonHint: @Sendable () async -> (cache: UInt64?, used: UInt64?) = { (nil, nil) }
    /// Cumulative guest CPU ticks (op `vm_usage`, busy excludes idle and I/O wait) without marking the VM active.
    /// Nil when unknown.
    public var cpuTicks: @Sendable () async -> (busy: UInt64, total: UInt64)? = { nil }
    /// The VM went away (sleep, crash or shutdown). Drop control connections.
    public var didStop: @Sendable () async -> Void = {}
    /// The VM just reached `running` and the agent answers on the control port.
    public var didBoot: @Sendable () async -> Void = {}
    public init() {}
}
