import Darwin
import Foundation

struct MacMachineProcessReading: Sendable {
    let processStart: UInt64
    let sampledAt: UInt64
    let cpuNanos: UInt64
    let physicalBytes: UInt64

    /// One fully used host core is 1.0.
    func coreFraction(since previous: Self) -> Double? {
        guard processStart == previous.processStart, sampledAt > previous.sampledAt,
              cpuNanos >= previous.cpuNanos else { return nil }
        return Double(cpuNanos - previous.cpuNanos) / Double(sampledAt - previous.sampledAt)
    }
}

actor MacMachineUsageSampler {
    struct Usage: Equatable, Sendable {
        let coreFraction: Double?
        let physicalBytes: UInt64

        var cpuText: String { coreFraction?.formatted(.percent.precision(.fractionLength(0))) ?? "—" }
        var memoryText: String { Fmt.bytes(Int(clamping: physicalBytes)) }
    }

    private let disk: URL
    private var worker: pid_t?
    private var previous: MacMachineProcessReading?
    private var nextLookup: UInt64 = 0

    init(disk: URL) { self.disk = disk }

    func sample() -> Usage? {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if worker == nil, now >= nextLookup {
            worker = Self.findWorker(for: disk)
            nextLookup = now + 8_000_000_000
        }
        guard let worker, let current = Self.read(worker),
              previous == nil || previous?.processStart == current.processStart else {
            self.worker = nil
            previous = nil
            return nil
        }
        defer { previous = current }
        return Usage(coreFraction: previous.flatMap { current.coreFraction(since: $0) }, physicalBytes: current.physicalBytes)
    }

    private static func read(_ pid: pid_t) -> MacMachineProcessReading? {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0 else { return nil }
        return MacMachineProcessReading(processStart: usage.ri_proc_start_abstime,
                                        sampledAt: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                                        cpuNanos: usage.ri_user_time + usage.ri_system_time,
                                        physicalBytes: usage.ri_phys_footprint)
    }

    private static func findWorker(for disk: URL) -> pid_t? {
        let uid = getuid()
        let stride = MemoryLayout<pid_t>.stride
        let estimate = Int(proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0))
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: estimate / stride + 32)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        // Launchd parents these XPC workers. Match the disk inode, so another running VM is never counted.
        var path = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        let workers = pids.prefix(Int(bytes) / stride).filter { pid in
            guard pid > 0 else { return false }
            let executable = path.withUnsafeMutableBufferPointer { buffer -> String? in
                guard let address = buffer.baseAddress, proc_pidpath(pid, address, UInt32(buffer.count)) > 0 else { return nil }
                return String(cString: address)
            }
            return executable?.hasPrefix("/System/Library/Frameworks/Virtualization.framework/") == true
                && executable?.hasSuffix("/com.apple.Virtualization.VirtualMachine") == true
                && holdsDisk(disk, pid: pid)
        }
        return workers.count == 1 ? workers.first : nil
    }

    static func holdsDisk(_ disk: URL, pid: pid_t) -> Bool {
        var file = stat()
        guard stat(disk.path, &file) == 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard estimate > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: estimate / stride + 8)
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return false }
        let size = Int32(MemoryLayout<vnode_fdinfo>.size)
        return descriptors.prefix(Int(bytes) / stride).contains { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return false }
            var vnode = vnode_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &vnode, size) == size else { return false }
            return vnode.pvi.vi_stat.vst_dev == UInt32(bitPattern: file.st_dev) && vnode.pvi.vi_stat.vst_ino == file.st_ino
        }
    }
}
