import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct AIAppsStoreTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        func add(_ args: [String]) { lock.lock(); all.append(args); lock.unlock() }
        var list: [[String]] { lock.lock(); defer { lock.unlock() }; return all }
    }

    @Test func installRemoveAndDeleteDataTouchOnlyThatAppsFolder() async throws {
        let dir = scratchPath("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Calls()
        let store = AIAppsStore(
            catalog: AICatalog.bundled().apps, containers: ContainersModel(service: DemoDocker(mode: .normal)), directory: dir,
            wiring: { .init(baseURL: "http://host.docker.internal:1/model-runner/k/v1", modelID: "m") },
            compose: { args, _ in calls.add(args); return .init(code: 0, output: "") })
        let webui = try #require(store.catalog.first { $0.id == "open-webui" })
        let n8n = try #require(store.catalog.first { $0.id == "n8n" })

        await store.install(webui)
        await store.install(n8n)
        let file = dir.appendingPathComponent("open-webui/compose.yaml")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("http://host.docker.internal:1/model-runner/k/v1"))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(calls.list[0].contains("up") && calls.list[0].contains("noodle-app-open-webui"))

        await store.remove(webui, deleteData: false)
        #expect(calls.list[2] == ["-p", "noodle-app-open-webui", "down", "--remove-orphans"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("open-webui").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("n8n/compose.yaml").path))

        await store.remove(n8n, deleteData: true)
        #expect(calls.list[3] == ["-p", "noodle-app-n8n", "down", "--remove-orphans", "--volumes"])
        #expect(store.error == nil)
    }

    @Test func controlCharactersInModelValuesAreRejected() {
        let app = AICatalog.bundled().apps[0]
        let bad = AIApp.ModelWiring(baseURL: "http://x\nINJECT: 1", modelID: "m")
        #expect(throws: AIApp.RenderError.unsafeValue) { try app.render(model: bad) }
    }
}
