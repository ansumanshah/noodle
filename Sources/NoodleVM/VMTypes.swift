import Foundation
import Virtualization
import NoodleCore
import os

public enum VMState: String, Sendable, Equatable {
    case stopped, starting, running, stopping
}

/// Which VM this is. The workload VM runs privileged and unconfined containers: it has its own disk and no Rosetta
/// share, and a Mac sharing device only when Kubernetes shared folders are on.
public enum VMRole: String, Sendable {
    case main, workload
}

public struct VMBootConfiguration: Sendable {
    public var role: VMRole
    public var kernel: URL
    public var initramfs: URL
    public var dataDisk: URL
    public var consoleLog: URL
    public var captureBootConsole: Bool
    public var cpus: Int
    public var memoryMiB: Int
    public var commandLine: String
    public var enableRosetta: Bool
    /// The `host` virtiofs device. Its share list holds only what containers bind (`setHostShares`).
    public var shareHostFolders: Bool

    public init(paths: NoodlePaths, settings: VMSettings, role: VMRole = .main, captureBootConsole: Bool? = nil) {
        self.role = role
        kernel = paths.kernel
        initramfs = paths.initramfs
        dataDisk = role == .main ? paths.dataDisk : paths.workloadDisk
        consoleLog = role == .main ? paths.vmLog : paths.workloadVMLog
        self.captureBootConsole = captureBootConsole ?? (ProcessInfo.processInfo.environment["NOODLE_BOOT_CONSOLE"] == "1"
            || FileManager.default.fileExists(atPath: paths.vmLog.path + ".enabled"))
        cpus = settings.cpus
        memoryMiB = settings.memoryMiB
        commandLine = GuestKernelArguments.commandLine(for: role)
        enableRosetta = role == .main
        shareHostFolders = role == .main || settings.workloadSharedFolders == true
    }
}

public enum VMError: Error, CustomStringConvertible, Sendable {
    case missingAsset(String)
    case invalidConfiguration(String)
    case notRunning
    case connectFailed(String)
    case startFailed(String)

    public var description: String {
        switch self {
        case .missingAsset(let s): return "missing VM asset: \(s)"
        case .invalidConfiguration(let s): return "invalid VM configuration: \(s)"
        case .notRunning: return "VM is not running"
        case .connectFailed(let s): return "vsock connect failed: \(s)"
        case .startFailed(let s): return "VM start failed: \(s)"
        }
    }
}
