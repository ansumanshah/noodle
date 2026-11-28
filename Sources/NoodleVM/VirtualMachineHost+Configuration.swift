import Foundation
import Virtualization
import NoodleCore
import os

extension VirtualMachineHost {
    func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        for (name, url) in [("kernel", config.kernel), ("initramfs", config.initramfs)] where !fm.fileExists(atPath: url.path) {
            throw VMError.missingAsset("\(name) at \(url.path)")
        }
        guard fm.fileExists(atPath: config.dataDisk.path) else { throw VMError.missingAsset("data disk at \(config.dataDisk.path)") }

        let c = VZVirtualMachineConfiguration()
        c.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(config.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        let mem = UInt64(config.memoryMiB) << 20
        c.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, min(mem, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let boot = VZLinuxBootLoader(kernelURL: config.kernel)
        boot.initialRamdiskURL = config.initramfs
        boot.commandLine = config.commandLine
        c.bootLoader = boot
        c.platform = VZGenericPlatformConfiguration()

        if config.captureBootConsole {
            let capture = try BootConsoleCapture(url: config.consoleLog, queue: queue)
            consoleCapture = capture
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: capture.writer)
            c.serialPorts = [serial]
        }

        // data disk
        let attachment = try VZDiskImageStorageDeviceAttachment(url: config.dataDisk, readOnly: false,
                                                                cachingMode: .automatic, synchronizationMode: .fsync)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        c.networkDevices = [net]

        var shares: [VZVirtioFileSystemDeviceConfiguration] = []
        if config.shareHostFolders {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "host")
            fs.share = VZMultipleDirectoryShare(directories: [:])
            shares.append(fs)
        }
        if config.enableRosetta, VZLinuxRosettaDirectoryShare.availability == .installed,
           let rosetta = try? VZLinuxRosettaDirectoryShare() {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            fs.share = rosetta
            shares.append(fs)
        }
        c.directorySharingDevices = shares

        do { try c.validate() } catch { throw VMError.invalidConfiguration("\(error)") }
        return c
    }
}
