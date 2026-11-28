import Foundation
import NoodleCore
import NoodleVM

/// One VM, its agent connection, and what the host believes that agent holds.
/// The engine owns two: the main VM for ordinary containers, and the workload VM for privileged and unconfined ones
/// Fields are only touched from the engine actor.
final class GuestRuntime: @unchecked Sendable {
    let role: VMRole
    let vm: VMController
    let guest: GuestClient
    var epoch = -1
    var setup: Task<Void, Error>?
    var setupEpoch = -1
    /// Containers the agent of the current boot knows about.
    var containers: Set<String> = []
    /// Hash of the last `create` each of those containers got, so an identical one is not sent again.
    var createdSpecs: [String: Int] = [:]
    var nets: Set<String> = []
    /// Layer digests known to be unpacked in this VM for the current boot. Cleared whenever the VM stops.
    var layers: Set<String> = []
    var unpacking: [String: Task<Void, Error>] = [:]
    var streamCount = 0
    var epochStart = Date()
    /// Ends the ordered guest event and stream count drains set up by `Engine.start()`.
    var closeFeeds: (() -> Void)?

    init(role: VMRole, paths: NoodlePaths, settings: VMSettings) {
        self.role = role
        vm = VMController(paths: paths, settings: settings, role: role)
        guest = GuestClient(vm: vm)
    }

    func forgetBoot() {
        containers = []; createdSpecs = [:]; nets = []; layers = []
    }
}

extension Engine {
    /// Privileged and `seccomp=unconfined` containers run in the workload VM, everything else in the main VM.
    nonisolated static func usesWorkload(_ c: ContainerRecord) -> Bool {
        c.hostConfig.Privileged || (c.hostConfig.SecurityOpt ?? []).contains(where: isUnconfined)
    }

    nonisolated static func isUnconfined(_ opt: String) -> Bool { opt == "seccomp=unconfined" || opt == "seccomp:unconfined" }

    // MARK: guest output is data

    /// One VM's agent speaks only for the containers routed to that VM. `containerRole` is nil for an unknown container.
    nonisolated static func eventAllowed(from source: VMRole, containerRole: VMRole?) -> Bool { source == containerRole }

    /// Guest-reported CPU time, split the way the stats API expects. Never overflows, whatever the guest says.
    nonisolated static func cpuSplit(_ ns: UInt64) -> (user: UInt64, kernel: UInt64) {
        let user = ns / 10 * 7 + (ns % 10) * 7 / 10
        return (user, ns - user)
    }

    /// Byte counts reported by a guest. Negative values count as zero.
    nonisolated static func saturatingBytes(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, over) = max(a, 0).addingReportingOverflow(max(b, 0))
        return over ? .max : r
    }

    nonisolated static func saturatingSum(_ base: UInt64, _ values: [UInt64]) -> UInt64 {
        values.reduce(base) { sum, v in
            let (r, over) = sum.addingReportingOverflow(v)
            return over ? .max : r
        }
    }

    func runtime(for c: ContainerRecord) -> GuestRuntime { Self.usesWorkload(c) ? workload : main }

    func runtime(_ id: String) -> GuestRuntime { containers[id].map(runtime(for:)) ?? main }

    var runtimes: [GuestRuntime] { [main, workload] }

    // MARK: removals recorded while a VM sleeps

    func pendingLists(_ rt: GuestRuntime) -> PendingRemovals.Lists {
        rt.role == .main
            ? PendingRemovals.Lists(containers: pendingRemovals.containers, volumes: pendingRemovals.volumes, layers: pendingRemovals.layers)
            : (pendingRemovals.workload ?? PendingRemovals.Lists())
    }

    func updatePending(_ rt: GuestRuntime, _ body: (inout PendingRemovals.Lists) -> Void) {
        var l = pendingLists(rt)
        body(&l)
        if rt.role == .main {
            pendingRemovals.containers = l.containers; pendingRemovals.volumes = l.volumes; pendingRemovals.layers = l.layers
        } else {
            pendingRemovals.workload = l.isEmpty ? nil : l
        }
    }

    /// The workload VM has a disk only after its first use. Before that there is nothing to clean.
    func workloadHasDisk() -> Bool { FileManager.default.fileExists(atPath: paths.workloadDisk.path) }

    /// Runtimes that may hold state worth cleaning.
    func cleanupRuntimes() -> [GuestRuntime] { workloadHasDisk() ? [main, workload] : [main] }
}
