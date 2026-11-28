import Foundation
import Testing
@testable import NoodleEngine
@testable import NoodleImages
import NoodleCore

/// Regressions where Noodle drifted from Docker: port conflicts, restart counts, removed networks, state and archive I/O.
@Suite struct EngineDockerSemanticsTests {
    @Test func wildcardPublishRefusesAPortAMacProgramHoldsOnLoopback() throws {
        let mac = try PortListener(proto: "tcp", hostIP: "127.0.0.1", hostPort: 0, containerIP: "10.0.0.2", containerPort: 80) { _, _, _ in
            throw EngineError.invalid("unused")
        }
        defer { mac.stop() }
        #expect {
            try PortListener(proto: "tcp", hostIP: "0.0.0.0", hostPort: mac.hostPort, containerIP: "10.0.0.2", containerPort: 80) { _, _, _ in
                throw EngineError.invalid("unused")
            }.stop()
        } throws: { error in
            guard case EngineError.portInUse(let m) = error else { return false }
            return m == "Bind for 0.0.0.0:\(mac.hostPort) failed: port is already allocated"
        }
    }

    @Test func restartBackoffDoublesAndResetsAfterALongRun() {
        #expect(Engine.restartBackoff(step: 0, ranFor: 0) == (0, 0.1))
        #expect(Engine.restartBackoff(step: 3, ranFor: 1) == (3, 0.8))
        #expect(Engine.restartBackoff(step: 3, ranFor: 11) == (0, 0.1))
        #expect(Engine.restartBackoff(step: 40, ranFor: 0).delay == 60)
    }

    @Test func removedNetworkStaysOnStoppedContainerAndBlocksStart() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        _ = try await engine.createNetwork(try JSONDecoder().decode(NetworkCreateRequest.self, from: Data(#"{"Name":"gone"}"#.utf8)))
        let req = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(#"{"Image":"tiny","HostConfig":{"NetworkMode":"gone"}}"#.utf8))
        let id = try await engine.createContainer(name: nil, request: req).id
        try await engine.removeNetwork("gone")
        #expect(await engine.containers[id]?.endpoints["gone"] != nil)
        await #expect { try await engine.startContainer(id) } throws: { error in
            guard case EngineError.notFound(let m) = error else { return false }
            return m == "network gone not found"
        }
        await engine.shutdown()
    }

    @Test func durableWriteReplacesTheFileAndLeavesNoTemp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-durable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        try ImageDurability.write(Data("old".utf8), to: file)
        try ImageDurability.write(Data("new".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"])
    }

    @Test func saveLoadAndImportRoundTripOffTheActor() async throws {
        let a = tempPaths(), b = tempPaths()
        defer { for p in [a, b] { try? FileManager.default.removeItem(at: p.root) } }
        let source = Engine(paths: a)
        try await source.start()
        let img = try await makeImage(source)
        let archive = a.root.appendingPathComponent("save.tar")
        try await source.saveImages(["tiny:latest"], to: archive)

        let target = Engine(paths: b)
        try await target.start()
        let loaded = try await target.loadImages(from: archive)
        #expect(loaded.map(\.id) == [img.id])
        #expect(loaded.first?.layers.map(\.digest) == img.layers.map(\.digest))
        #expect(loaded.first?.repoTags == ["tiny:latest"])
        #expect(await target.imageStore.pinned.isEmpty)

        let layer = try #require(img.layers.first)
        let imported = try await target.importImage(from: a.blobsDir.appendingPathComponent("sha256/" + layer.digest.dropFirst(7)), repo: "imp")
        #expect(imported.layers.map(\.digest) == [layer.digest])
        #expect(imported.repoTags == ["imp:latest"])
        await source.shutdown(); await target.shutdown()
    }
}
