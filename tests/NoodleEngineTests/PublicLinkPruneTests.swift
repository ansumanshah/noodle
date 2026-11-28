import Foundation
import Testing
import NoodleCore
@testable import NoodleEngine

@Suite struct PublicLinkPruneTests {
    @Test func prepareKeepsStoppedLinkWhoseSupervisorIsStillAlive() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let manager = PublicLinkManager(paths: paths)
        func status(_ id: String) -> PublicLinkStatus {
            PublicLinkStatus(id: id, containerID: "gone", containerName: "n", containerIP: "10.0.0.2", containerPort: 80, target: "http://127.0.0.1:1", state: "stopped")
        }
        manager.entries["alive"] = PublicLinkManager.Entry(status: status("alive"), process: Process())
        manager.entries["done"] = PublicLinkManager.Entry(status: status("done"))
        let listener = try PortListener(proto: "tcp", hostIP: "127.0.0.1", hostPort: 0, containerIP: "10.0.0.2", containerPort: 80) { _, _, _ in throw EngineError.invalid("unused") }
        defer { listener.stop() }
        let target = PublicLinkTarget(containerID: "other", containerName: "o", containerIP: "10.0.0.3", containerPort: 80)
        _ = try? manager.prepare(target, listener: listener, liveContainers: [])
        #expect(manager.entries["alive"] != nil)
        #expect(manager.entries["done"] == nil)
    }
}
