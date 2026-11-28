import Foundation
import Testing
@testable import NoodleCore

@Suite struct PathsTests {
    @Test func privilegedDataMovesOnceWithoutLosingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("workload")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: old.appendingPathComponent("data.img"))
        try Data("log".utf8).write(to: old.appendingPathComponent("vm.log"))
        let paths = NoodlePaths(root: root)
        try paths.ensureDirectories()
        try paths.ensureDirectories()
        #expect(paths.workloadDir.lastPathComponent == "privileged")
        #expect(try Data(contentsOf: paths.workloadDisk) == Data("disk".utf8))
        #expect(try Data(contentsOf: paths.workloadVMLog) == Data("log".utf8))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func conflictingPrivilegedFoldersArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["workload", "privileged"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: dir.appendingPathComponent("data.img"))
        }
        #expect(throws: (any Error).self) { try NoodlePaths(root: root).ensureDirectories() }
        for name in ["workload", "privileged"] {
            #expect(try Data(contentsOf: root.appendingPathComponent(name + "/data.img")) == Data(name.utf8))
        }
    }

    @Test func bootFilesPreferUserFilesThenResources() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("home")
        let resources = base.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let paths = NoodlePaths.resolve(environment: ["NOODLE_HOME": root.path, "NOODLE_RESOURCES": resources.path])
        try paths.ensureDirectories()
        let kernel = resources.appendingPathComponent("vmlinux")
        let ramdisk = resources.appendingPathComponent("initramfs.cpio.gz")
        try Data("kernel".utf8).write(to: kernel)
        try Data("ramdisk".utf8).write(to: ramdisk)
        #expect(paths.kernel == kernel)
        #expect(paths.initramfs == ramdisk)
        let local = paths.bootDir.appendingPathComponent("vmlinux")
        try Data("custom".utf8).write(to: local)
        #expect(paths.kernel == local)
        #expect(paths.initramfs == ramdisk)
        try FileManager.default.removeItem(at: ramdisk)
        #expect(paths.initramfs == paths.bootDir.appendingPathComponent("initramfs.cpio.gz"))
        #expect(try Data(contentsOf: local) == Data("custom".utf8))
    }

    @Test func appExecutableFindsBundleResources() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let contents = base.appendingPathComponent("Noodle.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let kernel = resources.appendingPathComponent("vmlinux")
        try Data("kernel".utf8).write(to: kernel)
        let paths = NoodlePaths.resolve(environment: ["NOODLE_HOME": base.appendingPathComponent("home").path],
                                        executableURL: contents.appendingPathComponent("MacOS/noodled"))
        #expect(paths.kernel == kernel)
    }
}
