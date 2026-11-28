import Foundation

/// The Linux command line for a Noodle VM, built from what the guest agent and the host need.
///
/// Required: the agent is PID 1 inside the initramfs, it logs boot steps to the virtio console, and a guest
/// panic must end the VM at once so the host sees a stop instead of a hung boot. Tuning: Noodle's idle memory
/// budget and wake target. Role: the workload VM tells the agent to skip its seccomp filter.
enum GuestKernelArguments {
    /// The agent binary inside the initramfs.
    static let agent = "rdinit=/init"
    /// Boot steps log to hvc0, the only console Virtualization.framework gives this guest.
    static let console = "console=hvc0"
    /// Reboot one second after a panic. Virtualization.framework treats a guest reboot as a stop.
    static let panicStops = "panic=1"

    /// Console output only for warnings: a quiet boot is a faster boot.
    static let quietConsole = "quiet"
    /// Every virtio device here is coherent, so no DMA bounce buffer: its default 64 MiB pool would count
    /// against the guest's resident memory.
    static let noBounceBuffer = "swiotlb=noforce"
    /// Expedited RCU grace periods. Namespace and mount teardown wait on them, on every container start and stop.
    static let fastGracePeriods = "rcupdate.rcu_expedited=1"

    static let workloadRole = "noodle.role=workload"

    static func arguments(for role: VMRole) -> [String] {
        var list = [agent, console, panicStops, quietConsole, noBounceBuffer, fastGracePeriods]
        if role == .workload { list.append(workloadRole) }
        return list
    }

    static func commandLine(for role: VMRole) -> String {
        arguments(for: role).joined(separator: " ")
    }
}
