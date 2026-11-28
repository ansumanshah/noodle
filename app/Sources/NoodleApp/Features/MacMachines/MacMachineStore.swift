import Foundation
import Observation
import Virtualization

/// One local guest. The app owns the VZ instance while it is running, even when its display is hidden.
/// VZVirtualMachine(configuration:) calls its delegate on the main queue.
@MainActor @Observable
final class MacMachineStore: NSObject, @preconcurrency VZVirtualMachineDelegate {
    enum Operation: Equatable {
        case installing, starting, forceStopping
    }

    private let locationFile: URL
    @ObservationIgnored private var diskLock: FileHandle?
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var checkedLocation = false
    private(set) var files: MacMachineFiles?
    private(set) var profile: MacMachineProfile?
    private(set) var machine: VZVirtualMachine?
    private(set) var operation: Operation?
    private(set) var installationProgress: Progress?
    private(set) var shutdownRequested = false
    private(set) var usage: MacMachineUsageSampler.Usage?
    var error: String?

    init(home: URL) { locationFile = home.appendingPathComponent("macos-machine-location.json") }

    var isActive: Bool { operation != nil || machine != nil }
    var isRunning: Bool { operation == nil && machine != nil && !shutdownRequested }
    var statusText: String {
        switch operation {
        case .installing: String(localized: "Installing")
        case .starting: String(localized: "Starting")
        case .forceStopping: String(localized: "Stopping")
        case nil:
            if machine != nil { shutdownRequested ? String(localized: "Shutdown requested") : String(localized: "Running") }
            else if profile != nil { String(localized: "Off") }
            else if files != nil { error == nil ? String(localized: "Saved") : String(localized: "Unavailable") }
            else { String(localized: "Set up") }
        }
    }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        if visible, !checkedLocation {
            checkedLocation = true
            files = try? savedFiles()
        }
        updateUsageSampling()
    }

    private func updateUsageSampling() {
        usageTask?.cancel()
        usageTask = nil
        usage = nil
        guard windowVisible, machine != nil, operation != .starting, let disk = files?.disk else { return }
        usageTask = Task { [weak self] in
            let sampler = MacMachineUsageSampler(disk: disk)
            await poll(every: .seconds(2), tolerance: .milliseconds(250)) {
                let next = await sampler.sample()
                guard !Task.isCancelled else { return }
                if self?.usage != next { self?.usage = next }
            }
        }
    }

    func reload() {
        guard !isActive else { return }
        checkedLocation = true
        files = nil
        profile = nil
        error = nil
        do {
            guard let files = try savedFiles() else { return }
            self.files = files
            profile = try files.load()
        } catch {
            self.error = "Couldn’t open the saved macOS machine. Reconnect its drive or choose Open Existing. \(error.localizedDescription)"
        }
    }

    private func savedFiles() throws -> MacMachineFiles? {
        guard FileManager.default.fileExists(atPath: locationFile.path) else { return nil }
        let directory = try JSONDecoder().decode(URL.self, from: Data(contentsOf: locationFile))
        return MacMachineFiles(directory: directory)
    }

    func openExisting(_ directory: URL) {
        guard !isActive else { return }
        error = nil
        do { try select(MacMachineFiles(directory: directory)) }
        catch { self.error = error.localizedDescription }
    }

    private func select(_ files: MacMachineFiles) throws {
        let profile = try files.load()
        try FileManager.default.createDirectory(at: locationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(files.directory).write(to: locationFile, options: .atomic)
        self.files = files
        self.profile = profile
    }

    static func appleRestoreImageURL() async throws -> URL {
        guard VZVirtualMachine.isSupported else { throw MacMachineError.unsupportedHost }
        let image = try await VZMacOSRestoreImage.latestSupported
        guard image.url.scheme == "https" else { throw MacMachineError.invalidDownloadURL }
        return image.url
    }

    func install(from restoreImage: URL, in parent: URL) async {
        guard !isActive, profile == nil else { return }
        error = nil
        operation = .installing
        defer { installationProgress = nil; operation = nil }

        let imageAccess = restoreImage.startAccessingSecurityScopedResource()
        let parentAccess = parent.startAccessingSecurityScopedResource()
        defer {
            if imageAccess { restoreImage.stopAccessingSecurityScopedResource() }
            if parentAccess { parent.stopAccessingSecurityScopedResource() }
        }
        do {
            guard VZVirtualMachine.isSupported else { throw MacMachineError.unsupportedHost }
            let destination = MacMachineFiles(directory: parent.appendingPathComponent(MacMachineFiles.folderName, isDirectory: true))
            guard !FileManager.default.fileExists(atPath: destination.directory.path) else { throw MacMachineError.destinationExists }
            let free = try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            guard let free, UInt64(max(0, free)) >= MacMachineFiles.minimumFreeSpace else { throw MacMachineError.insufficientStorage }
            let image = try await VZMacOSRestoreImage.image(from: restoreImage)
            guard let requirements = image.mostFeaturefulSupportedConfiguration else { throw MacMachineError.unsupportedImage }
            let memory = max(4 * MacMachineFiles.gib, requirements.minimumSupportedMemorySize)
            let staging = try MacMachineFiles.stage(in: parent)
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at: staging.directory) } }
            let profile = MacMachineProfile(
                osVersion: "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)",
                osBuild: image.buildVersion, cpus: max(4, requirements.minimumSupportedCPUCount), memory: memory,
                hardwareModel: requirements.hardwareModel.dataRepresentation,
                machineIdentifier: VZMacMachineIdentifier().dataRepresentation
            )
            try await installImage(restoreImage, on: staging, profile: profile, hardware: requirements.hardwareModel)
            try staging.save(profile)
            try staging.publish(to: destination)
            published = true
            do { try select(destination) }
            catch {
                self.files = destination
                self.profile = profile
                self.error = "Installed macOS. Noodle couldn’t save its location. To reopen it later, choose \(destination.directory.path)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func installImage(_ url: URL, on files: MacMachineFiles, profile: MacMachineProfile, hardware: VZMacHardwareModel) async throws {
        try files.createDisk()
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: files.auxiliaryStorage, hardwareModel: hardware, options: [])
        let vm = try Self.makeMachine(files: files, profile: profile)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: url)
        installationProgress = installer.progress
        try await installer.install()
    }

    func start() async {
        guard !isActive, let files, profile != nil else { return }
        error = nil
        operation = .starting
        defer { operation = nil; updateUsageSampling() }
        do {
            guard VZVirtualMachine.isSupported else { throw MacMachineError.unsupportedHost }
            let lock = try files.lock()
            let profile = try files.load()
            let vm = try Self.makeMachine(files: files, profile: profile)
            vm.delegate = self
            diskLock = lock
            self.profile = profile
            machine = vm
            try await vm.start()
        } catch {
            if let machine { didStop(machine) }
            self.error = error.localizedDescription
        }
    }

    func requestShutdown() {
        guard operation == nil, let machine else { return }
        do {
            try machine.requestStop()
            shutdownRequested = self.machine === machine
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    func forceStop() async {
        guard operation == nil, let vm = machine else { return }
        operation = .forceStopping
        defer { operation = nil }
        do { try await vm.stop(); didStop(vm) }
        catch { self.error = error.localizedDescription }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { didStop(virtualMachine) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        didStop(virtualMachine)
        self.error = error.localizedDescription
    }

    private func didStop(_ vm: VZVirtualMachine) {
        guard machine === vm else { return }
        machine = nil
        diskLock = nil
        shutdownRequested = false
        updateUsageSampling()
    }

    private static func makeMachine(files: MacMachineFiles, profile: MacMachineProfile) throws -> VZVirtualMachine {
        guard profile.memory <= ProcessInfo.processInfo.physicalMemory / 2 else {
            let gib = profile.memory / MacMachineFiles.gib
            throw MacMachineError.insufficientMemory(gib)
        }
        guard let hardware = VZMacHardwareModel(dataRepresentation: profile.hardwareModel), hardware.isSupported,
              let identifier = VZMacMachineIdentifier(dataRepresentation: profile.machineIdentifier) else {
            throw MacMachineError.invalidPlatform
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: files.auxiliaryStorage)

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = profile.cpus
        config.memorySize = profile.memory
        let storage = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: storage)]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 110)]
        config.graphicsDevices = [graphics]
        // Guests before macOS 13 use the USB devices. Newer guests prefer the Mac devices.
        config.keyboards = [VZMacKeyboardConfiguration(), VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try config.validate()
        return VZVirtualMachine(configuration: config)
    }
}
