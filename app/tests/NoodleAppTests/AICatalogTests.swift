import Foundation
import Testing
@testable import NoodleApp

@Suite struct AICatalogTests {
    private static let wiring = AIApp.ModelWiring(baseURL: "http://host.docker.internal:11346/model-runner/k3y/v1", modelID: "gemma4")
    private static var catalog: [AIApp] { AICatalog.bundled().apps }

    @Test func bundledCatalogDecodesWithThreeApps() {
        #expect(Self.catalog.map(\.id) == ["open-webui", "anythingllm", "n8n"])
        #expect(Set(Self.catalog.map(\.port)).count == 3)
    }

    @Test func imagesArePinned() {
        for app in Self.catalog {
            let images = app.compose.filter { $0.contains("image:") }.map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
            #expect(!images.isEmpty)
            for image in images { #expect(image.contains(":") && !image.hasSuffix(":latest"), "\(app.id) \(image)") }
        }
    }

    @Test func everyTemplateRendersWithTheModelFilledIn() throws {
        for app in Self.catalog {
            let yaml = try app.render(model: app.usesModel ? Self.wiring : nil)
            #expect(!yaml.contains("{{"), "\(app.id) left a placeholder")
            #expect(yaml.contains("127.0.0.1:\(app.port):"))
            #expect(yaml.contains("volumes:"), "\(app.id) keeps data in a named volume")
            #expect(app.usesModel == yaml.contains(Self.wiring.baseURL))
            if app.usesModel { #expect(yaml.contains("gemma4") || app.id == "open-webui") }
        }
    }

    @Test func modelAppsRefuseToRenderWithoutAnAddress() {
        let webui = Self.catalog[0]
        #expect(throws: AIApp.RenderError.needsModel) { try webui.render(model: nil) }
    }

    @Test func rendersAreValidComposeYAML() throws {
        let ruby = "/usr/bin/ruby"
        try #require(FileManager.default.isExecutableFile(atPath: ruby), "ruby not available")
        for app in Self.catalog {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).yaml")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data(app.render(model: app.usesModel ? Self.wiring : nil).utf8).write(to: file)
            let process = Process()
            process.executableURL = URL(filePath: ruby)
            process.arguments = ["-ryaml", "-e", """
                d = YAML.safe_load(File.read(ARGV[0]))
                s = d.fetch("services").fetch(ARGV[1])
                abort("no image") unless s["image"].to_s.include?(":")
                abort("no volume") unless d.fetch("volumes").is_a?(Hash)
                """, file.path, app.service]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(app.id) is not valid Compose YAML")
        }
    }

    @Test func quotesInTheModelAddressStayInsideTheYAMLString() throws {
        let odd = AIApp.ModelWiring(baseURL: "http://h/\"x", modelID: "a\\b")
        let yaml = try Self.catalog[0].render(model: odd)
        #expect(yaml.contains("\\\"x"))
    }

    // MARK: - Installed state

    private func container(_ project: String?, service: String = "app", state: String = "running", port: Int? = nil) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project; labels["com.docker.compose.service"] = service }
        return ContainerSummary(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), names: ["/x"], image: "i",
                                state: state, status: state, created: 0,
                                ports: port.map { [PortMapping(ip: "127.0.0.1", privatePort: 8080, publicPort: $0, type: "tcp")] } ?? [],
                                labels: labels)
    }

    @Test func stateComesFromTheProjectLabel() {
        let app = Self.catalog[0]
        #expect(app.project == "noodle-app-open-webui")
        #expect(app.state(in: []) == .notInstalled)
        #expect(app.state(in: [container("other"), container(nil)]) == .notInstalled)
        #expect(app.state(in: [container(app.project)]) == .running)
        #expect(app.state(in: [container(app.project, state: "exited")]) == .stopped)
        #expect(app.state(in: [container(app.project, state: "exited"), container(app.project)]) == .running)
        #expect(Self.catalog[1].state(in: [container(app.project)]) == .notInstalled)
    }

    @Test func openPrefersTheLocalNameThenThePublishedPort() {
        let app = Self.catalog[0]
        let web = container(app.project, port: 3123)
        #expect(app.openURL(in: [web], names: LocalNameTable()).absoluteString == "http://localhost:3123")
        let names = LocalNameTable(entries: [.init(host: "open-webui.localhost", containerID: String(web.id.prefix(12)))])
        #expect(app.openURL(in: [web], names: names).absoluteString == "http://open-webui.localhost")
        #expect(app.openURL(in: [], names: LocalNameTable()).absoluteString == "http://localhost:\(app.port)")
    }

    @Test func progressUsesPlainWords() {
        #expect(AIAppProgress.words(for: " ✔ Image ghcr.io/x Pulled")?.contains("Downloading") == true)
        #expect(AIAppProgress.words(for: "Container x-app-1 Started") == "Starting…")
        #expect(AIAppProgress.words(for: "unrelated") == nil)
    }
}
