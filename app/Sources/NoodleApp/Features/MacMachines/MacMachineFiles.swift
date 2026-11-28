import Darwin
import Foundation

struct MacMachineProfile: Codable, Equatable {
    let osVersion: String
    let osBuild: String
    let cpus: Int
    let memory: UInt64
    let hardwareModel: Data
    let machineIdentifier: Data
}

struct MacMachineFiles: Equatable {
    static let folderName = "Noodle Mac.noodlemac"
    static let gib: UInt64 = 1 << 30
    static let diskSize = 64 * gib
    static let minimumFreeSpace = 40 * gib

    let directory: URL
    var disk: URL { directory.appendingPathComponent("Disk.img") }
    var auxiliaryStorage: URL { directory.appendingPathComponent("AuxiliaryStorage") }
    private var profile: URL { directory.appendingPathComponent("Machine.json") }

    func load() throws -> MacMachineProfile {
        for file in [profile, disk, auxiliaryStorage] {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else {
                throw MacMachineError.incompleteMachine
            }
        }
        return try JSONDecoder().decode(MacMachineProfile.self, from: Data(contentsOf: profile))
    }

    func save(_ value: MacMachineProfile) throws {
        try JSONEncoder().encode(value).write(to: profile, options: .atomic)
    }

    func createDisk() throws {
        let fd = open(disk.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        guard ftruncate(fd, off_t(Self.diskSize)) == 0 else { throw Self.posixError() }
    }

    // Keep the descriptor for the lifetime of the VM. The kernel releases it after a crash.
    func lock() throws -> FileHandle {
        let fd = open(directory.appendingPathComponent("Lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error: any Error = errno == EWOULDBLOCK ? MacMachineError.inUse : Self.posixError()
            close(fd)
            throw error
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func stage(in parent: URL) throws -> MacMachineFiles {
        let directory = parent.appendingPathComponent("Noodle Mac Installing \(UUID().uuidString.prefix(8))", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw posixError() }
        return MacMachineFiles(directory: directory)
    }

    func publish(to destination: MacMachineFiles) throws {
        guard renamex_np(directory.path, destination.directory.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw MacMachineError.destinationExists }
            throw Self.posixError()
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

enum MacMachineError: LocalizedError, Equatable {
    case unsupportedHost, unsupportedImage, invalidPlatform, incompleteMachine, inUse, destinationExists
    case insufficientStorage, insufficientMemory(UInt64), invalidDownloadURL

    var errorDescription: String? {
        switch self {
        case .unsupportedHost: "This Mac can’t run a macOS virtual machine."
        case .unsupportedImage: "Choose an Apple macOS restore image compatible with this Mac."
        case .invalidPlatform: "This macOS machine’s saved hardware is incompatible with this Mac."
        case .incompleteMachine: "The selected folder is missing the macOS machine’s disk or configuration."
        case .inUse: "This macOS machine is already open in another Noodle process."
        case .destinationExists: "A Noodle Mac already exists in this folder. Open it or choose another storage folder."
        case .insufficientStorage: "Choose a storage folder with at least 40 GiB free for the macOS guest."
        case .insufficientMemory(let gib): "This restore image needs \(gib) GiB of guest memory. Use a Mac with more available capacity."
        case .invalidDownloadURL: "Apple did not return a secure restore image link."
        }
    }
}
