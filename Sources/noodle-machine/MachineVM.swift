import Foundation
import Virtualization

struct MachineSpec {
    var directory: URL
    var kernel: URL
    var initramfs: URL
    var cpus: Int
    var memoryMiB: Int
    var user: String
    var uid: UInt32
    var host: String
    var share: URL?
    var seed: Bool
    var systemd: Bool = false
    var workload: Bool = false

    var disk: URL { directory.appendingPathComponent("disk.img") }
    var seedDisk: URL { directory.appendingPathComponent("seed.tar") }
    var console: URL { directory.appendingPathComponent("console.log") }
}

enum MachineError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let s) = self { return s } else { return "" } }
}

/// One Virtualization.framework VM for one machine: its own kernel state, its own disk, and a directory share
/// only when the machine was created with one. Every VZ call runs on `queue`.
final class MachineVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "noodle.machine.vm", qos: .userInitiated)
    private var vm: VZVirtualMachine?
    private var socket: VZVirtioSocketDevice?
    private let spec: MachineSpec
    private let onStop: @Sendable (Error?) -> Void

    init(spec: MachineSpec, onStop: @escaping @Sendable (Error?) -> Void) {
        self.spec = spec
        self.onStop = onStop
    }

    private func configuration() throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(spec.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        c.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, min(UInt64(spec.memoryMiB) << 20, VZVirtualMachineConfiguration.maximumAllowedMemorySize))
        let boot = VZLinuxBootLoader(kernelURL: spec.kernel)
        boot.initialRamdiskURL = spec.initramfs
        var line = "console=hvc0 rdinit=/init quiet panic=1 noodle.user=\(spec.user) noodle.uid=\(spec.uid) noodle.host=\(spec.host)"
        if spec.workload { line = "rdinit=/init quiet panic=1 noodle.role=workload" }
        if spec.share != nil { line += " noodle.share=1" }
        if spec.systemd { line += " noodle.systemd=1 systemd.unified_cgroup_hierarchy=1" }
        boot.commandLine = line
        c.bootLoader = boot
        c.platform = VZGenericPlatformConfiguration()

        // Raw workloads have no console device or log file by default.
        if !spec.workload {
            let fm = FileManager.default
            if !fm.fileExists(atPath: spec.console.path) { _ = fm.createFile(atPath: spec.console.path, contents: nil) }
            let log = try FileHandle(forWritingTo: spec.console)
            try log.truncate(atOffset: 0)
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: log)
            c.serialPorts = [serial]
        }

        var disks = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
            url: spec.disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync))]
        if spec.seed {
            disks.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: spec.seedDisk, readOnly: true)))
        }
        c.storageDevices = disks
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        c.networkDevices = [net]
        if let share = spec.share {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "share")
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share, readOnly: false))
            c.directorySharingDevices = [fs]
        }
        try c.validate()
        return c
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let machine = VZVirtualMachine(configuration: try configuration(), queue: queue)
                    machine.delegate = self
                    vm = machine
                    socket = machine.socketDevices.first as? VZVirtioSocketDevice
                    machine.start { cont.resume(with: $0.mapError { MachineError.message("start failed: \($0)") }) }
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Connect to the guest agent. Returns an owned descriptor.
    func connect(port: UInt32, _ done: @escaping @Sendable (Int32?) -> Void) {
        queue.async { [self] in
            guard let dev = socket, vm?.state == .running else { done(nil); return }
            dev.connect(toPort: port) { result in
                guard case .success(let conn) = result else { done(nil); return }
                let fd = dup(conn.fileDescriptor)
                conn.close()
                done(fd >= 0 ? fd : nil)
            }
        }
    }

    func forceStop(_ done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard let machine = vm, machine.canStop else { done(); return }
            machine.stop { _ in done() }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { onStop(nil) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { onStop(error) }
}
