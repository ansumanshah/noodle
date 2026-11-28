import Foundation
import NoodleCore
import Testing

private final class ModelPluginTestBundle: NSObject {}

@Suite("ModelToolPluginFirstUse")
struct ModelToolPluginFirstUseTests {
    private static let upstream = URL(fileURLWithPath: "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-model")
    private static var hasPinnedUpstream: Bool {
        guard let pin = Tools.pins.first(where: { $0.name == "docker-model" }) else { return false }
        return (try? Digest.sha256(file: upstream)) == "sha256:" + pin.sha256
    }

    @Test(.enabled(if: Self.hasPinnedUpstream, "Requires the pinned upstream Docker Desktop CLI for offline first-use verification"))
    func installsAndRepairsVerifiedUpstreamWithoutADaemon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-model-tool-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = Bundle(for: ModelPluginTestBundle.self).bundleURL
        let binary = ProcessInfo.processInfo.environment["NOODLE_BIN"].map { URL(fileURLWithPath: $0) }
            ?? (bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle).appendingPathComponent("noodle")
        let home = root.appendingPathComponent("data")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.appendingPathComponent("user").path
        environment["NOODLE_HOME"] = home.path
        environment["DOCKER_CONFIG"] = root.appendingPathComponent("docker").path
        environment["NOODLE_NO_LAUNCHCTL"] = "1"
        environment["NOODLE_TOOLS_MIRROR"] = nil
        func run(_ arguments: [String]) throws -> Data {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "Model tool fixture command failed: \(String(decoding: data, as: UTF8.self))")
            return data
        }
        _ = try run(["tools", "install", "--no-link", "docker-model"])
        let cached = Tools.pluginDirectory(NoodlePaths(root: home)).appendingPathComponent("docker-model")
        let expected = try Digest.sha256(file: Self.upstream)
        #expect(try Digest.sha256(file: cached) == expected)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("run/docker.sock").path))
        let metadata = try run(["__tool-plugin", "docker-model", home.path, root.appendingPathComponent("docker-model").path,
                                "docker-cli-plugin-metadata"])
        let fields = try JSONDecoder().decode([String: String].self, from: metadata)
        #expect(fields["Vendor"] == "Docker Inc.")
        #expect(fields["Version"] == "v1.2.9")
        try Data("tampered".utf8).write(to: cached)
        _ = try run(["tools", "install", "--no-link", "docker-model"])
        #expect(try Digest.sha256(file: cached) == expected)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("docker/cli-plugins/docker-model").path))
    }
}
