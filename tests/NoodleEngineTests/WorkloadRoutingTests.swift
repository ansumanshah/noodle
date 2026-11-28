import Foundation
import Testing
@testable import NoodleCore
@testable import NoodleEngine
@testable import NoodleVM

@Suite struct WorkloadRoutingTests {
    private func record(_ edit: (inout HostConfig) -> Void) -> ContainerRecord {
        var hc = HostConfig()
        edit(&hc)
        return ContainerRecord(id: "a", name: "a", created: Date(), image: "i", imageID: "x", config: ContainerConfig(), hostConfig: hc)
    }

    @Test func privilegedAndUnconfinedGoToTheWorkloadVM() {
        #expect(!Engine.usesWorkload(record { _ in }))
        #expect(Engine.usesWorkload(record { $0.Privileged = true }))
        #expect(Engine.usesWorkload(record { $0.SecurityOpt = ["seccomp=unconfined"] }))
        #expect(Engine.usesWorkload(record { $0.SecurityOpt = ["seccomp:unconfined"] }))
        #expect(!Engine.usesWorkload(record { $0.SecurityOpt = ["no-new-privileges"] }))
        #expect(!Engine.usesWorkload(record { $0.CapAdd = ["NET_ADMIN"] }))
    }

    // A refused privileged bind must not leave its missing source folder behind on the Mac.
    @Test func refusedPrivilegedBindCreatesNothing() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let missing = paths.root.appendingPathComponent("not-made/deeper").path
        let body = #"{"Image":"tiny","HostConfig":{"Privileged":true,"Binds":["\#(missing):/x"]}}"#
        let req = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(body.utf8))
        await #expect(throws: EngineError.self) { try await engine.createContainer(name: nil, request: req) }
        #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("not-made").path))
        await engine.shutdown()
    }

    @Test func workloadVMHasItsOwnDiskLogAndNoShares() {
        let paths = NoodlePaths(root: URL(fileURLWithPath: "/tmp/noodle-routing"))
        let main = VMBootConfiguration(paths: paths, settings: .defaults())
        let work = VMBootConfiguration(paths: paths, settings: .defaults(), role: .workload)
        #expect(main.dataDisk == paths.dataDisk)
        #expect(work.dataDisk == paths.workloadDisk)
        #expect(work.dataDisk != main.dataDisk && work.consoleLog != main.consoleLog)
        #expect(work.commandLine.contains("noodle.role=workload"))
        #expect(!main.commandLine.contains("noodle.role"))
        #expect(main.enableRosetta && !work.enableRosetta)
        #expect(main.shareHostFolders && !work.shareHostFolders)
    }

    // The workload VM's share device exists only with the setting on, and it only gets approved folders.
    @Test func workloadSharingDeviceFollowsTheSetting() {
        let paths = NoodlePaths(root: URL(fileURLWithPath: "/tmp/noodle-routing"))
        var s = VMSettings.defaults()
        #expect(s.workloadSharedFolders == nil)
        #expect(!VMBootConfiguration(paths: paths, settings: s, role: .workload).shareHostFolders)
        s.workloadSharedFolders = false
        #expect(!VMBootConfiguration(paths: paths, settings: s, role: .workload).shareHostFolders)
        s.workloadSharedFolders = true
        #expect(VMBootConfiguration(paths: paths, settings: s, role: .workload).shareHostFolders)
        #expect(!VMBootConfiguration(paths: paths, settings: s, role: .workload).enableRosetta)
    }

    @Test func workloadBindsOnlyApprovedFoldersAndNoneWhenOff() throws {
        let root = try VMSettings.canonicalDirectory(FileManager.default.temporaryDirectory.path)
        let approved = root + "/noodle-wl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: approved + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: approved) }
        var s = VMSettings(cpus: 2, memoryMiB: 1024, approvedDirectories: [approved])
        for path in [approved, approved + "/sub", approved + "/sub/file.txt"] {
            #expect(s.workloadBindRefusal(path) != nil, "off: \(path)")
        }
        s.workloadSharedFolders = true
        for path in [approved, approved + "/sub", approved + "/sub/file.txt"] {
            #expect(s.workloadBindRefusal(path) == nil, "on: \(path)")
        }
        for path in [root, approved + "-sibling", "/Users", "/"] {
            #expect(s.workloadBindRefusal(path) != nil, "not approved: \(path)")
        }
        s.approvedDirectories = []
        #expect(s.workloadBindRefusal(approved) != nil)
    }

    @Test func workloadBindsRefuseEscapesAndOddSpellings() throws {
        let root = try VMSettings.canonicalDirectory(FileManager.default.temporaryDirectory.path)
        let base = root + "/noodle-wl-\(UUID().uuidString)"
        let approved = base + "/Approved", outside = base + "/outside"
        let fm = FileManager.default
        try fm.createDirectory(atPath: approved, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: approved + "/escape", withDestinationPath: outside)
        defer { try? fm.removeItem(atPath: base) }
        var s = VMSettings(cpus: 2, memoryMiB: 1024, approvedDirectories: [approved])
        s.workloadSharedFolders = true
        #expect(s.workloadBindRefusal(approved) == nil)
        #expect(s.workloadBindRefusal(approved + "/../outside")?.contains("canonical") == true)
        #expect(s.workloadBindRefusal(approved + "/escape")?.contains("canonical") == true)
        #expect(s.workloadBindRefusal(approved + "/") != nil)
        #expect(s.workloadBindRefusal("relative/path") != nil)
        // APFS is case-insensitive, but a case variant is not the approved spelling: it fails closed.
        #expect(s.workloadBindRefusal(base + "/approved") != nil)
        // The node skips a folder whose path has ':' (it cannot be spelled in `-v`); privileged binds still work.
        let colon = base + "/a:b"
        try fm.createDirectory(atPath: colon, withIntermediateDirectories: true)
        s.approvedDirectories = [approved, colon, base + "/gone"]
        #expect(s.kubernetesNodeFolders == [approved])
        #expect(s.workloadBindRefusal(colon) == nil)
    }

    @Test func workloadSharingSettingRoundTripsAndSurvivesForms() throws {
        let missing = try JSONDecoder().decode(VMSettings.self, from: Data("{}".utf8))
        #expect(missing.workloadSharedFolders == nil)
        var on = VMSettings.defaults(); on.workloadSharedFolders = true
        let decoded = try JSONDecoder().decode(VMSettings.self, from: try JSONEncoder().encode(on))
        #expect(decoded.workloadSharedFolders == true)
        #expect(VMSettings.defaults().keepingFileManagedValues(from: on).workloadSharedFolders == true)
    }

    @Test func pendingRemovalsRoundTripWithAndWithoutWorkloadLists() throws {
        var p = Engine.PendingRemovals()
        p.volumes = ["v"]
        let old = try JSONDecoder().decode(Engine.PendingRemovals.self, from: JSONEncoder().encode(p))
        #expect(old.workload == nil)
        p.workload = .init(containers: ["c"], volumes: ["w"], layers: [])
        let back = try JSONDecoder().decode(Engine.PendingRemovals.self, from: JSONEncoder().encode(p))
        #expect(back.workload?.volumes == ["w"])
        // State written before the workload VM existed has no such key.
        let legacy = try JSONDecoder().decode(Engine.PendingRemovals.self, from: Data(#"{"containers":[],"volumes":["x"],"layers":[]}"#.utf8))
        #expect(legacy.volumes == ["x"] && legacy.workload == nil)
    }
}
