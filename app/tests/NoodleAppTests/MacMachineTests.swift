import Darwin
import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct MacMachineTests {
    private let profile = MacMachineProfile(osVersion: "26.0", osBuild: "fixture", cpus: 4,
                                            memory: 4 * MacMachineFiles.gib,
                                            hardwareModel: Data([1]), machineIdentifier: Data([2]))

    @Test func diskIsSparseAndCreationPreservesExistingData() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = try MacMachineFiles.stage(in: home)
        try files.createDisk()
        let attributes = try files.disk.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        #expect(attributes.fileSize == Int(MacMachineFiles.diskSize))
        #expect(try #require(attributes.fileAllocatedSize) < 1_048_576)
        #expect(throws: POSIXError.self) { try files.createDisk() }
    }

    @Test func publishCannotReplaceAnExistingGuest() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = try MacMachineFiles.stage(in: home)
        let incoming = try MacMachineFiles.stage(in: home)
        let destination = MacMachineFiles(directory: home.appendingPathComponent(MacMachineFiles.folderName, isDirectory: true))
        try installed.publish(to: destination)
        #expect(throws: MacMachineError.destinationExists) { try incoming.publish(to: destination) }
        #expect(FileManager.default.fileExists(atPath: incoming.directory.path))
        #expect(FileManager.default.fileExists(atPath: destination.directory.path))
    }

    @Test func runningMachineLockPreventsAnotherStart() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = try MacMachineFiles.stage(in: home)
        let lock = try files.lock()
        #expect(throws: MacMachineError.inUse) { try files.lock() }
        try lock.close()
        // A child another test is spawning can hold a copy of the descriptor until it execs.
        var again = try? files.lock()
        for _ in 0..<50 where again == nil { usleep(100_000); again = try? files.lock() }
        try #require(again).close()
    }

    @Test func selectionSurvivesRelaunchAndMissingStorageCanBeReconnected() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = try MacMachineFiles.stage(in: home)
        let first = MacMachineStore(home: home)
        first.openExisting(files.directory)
        #expect(first.profile == nil)
        try Data().write(to: files.auxiliaryStorage)
        try files.createDisk()
        try files.save(profile)
        first.openExisting(files.directory)
        #expect(first.profile == profile)

        let reopened = MacMachineStore(home: home)
        reopened.setWindowVisible(true)
        #expect(reopened.files == files && reopened.profile == nil && reopened.statusText == "Saved")
        reopened.reload()
        #expect(reopened.profile == profile && reopened.files == files)
        let moved = home.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: files.directory, to: moved)
        reopened.reload()
        #expect(reopened.profile == nil && reopened.error != nil)
        reopened.openExisting(moved)
        #expect(reopened.profile == profile && reopened.error == nil)
    }

    @Test func selectionRejectsLinkedStorage() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = try MacMachineFiles.stage(in: home)
        try files.save(profile)
        let outside = home.appendingPathComponent("host-file")
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: files.disk, withDestinationURL: outside)
        try Data().write(to: files.auxiliaryStorage)
        #expect(throws: MacMachineError.incompleteMachine) { try files.load() }
    }

    @Test func diskOwnershipMatchesAnOpenDescriptor() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = try MacMachineFiles.stage(in: home)
        try files.createDisk()
        try Data().write(to: files.auxiliaryStorage)
        let disk = try FileHandle(forReadingFrom: files.disk)
        #expect(MacMachineUsageSampler.holdsDisk(files.disk, pid: getpid()))
        #expect(!MacMachineUsageSampler.holdsDisk(files.auxiliaryStorage, pid: getpid()))
        try disk.close()
        #expect(!MacMachineUsageSampler.holdsDisk(files.disk, pid: getpid()))
    }

    @Test func cpuFractionUsesHostCoresAndRejectsAReusedProcess() {
        let first = MacMachineProcessReading(processStart: 1, sampledAt: 1_000, cpuNanos: 500, physicalBytes: 1)
        let second = MacMachineProcessReading(processStart: 1, sampledAt: 2_000, cpuNanos: 2_000, physicalBytes: 2)
        let reused = MacMachineProcessReading(processStart: 2, sampledAt: 3_000, cpuNanos: 3_000, physicalBytes: 3)
        #expect(second.coreFraction(since: first) == 1.5)
        #expect(reused.coreFraction(since: second) == nil)
        #expect(first.coreFraction(since: second) == nil)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-mac-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
