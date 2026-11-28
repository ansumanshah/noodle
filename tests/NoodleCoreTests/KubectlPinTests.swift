import Testing
@testable import NoodleCore

@Suite struct KubectlPinTests {
    @Test func kubectlIsAPinnedSingleBinaryNotADockerPlugin() throws {
        let pin = try #require(Tools.extras.first { $0.name == "kubectl" })
        #expect(pin.kind == .binary)
        #expect(pin.version == "1.37.2")
        #expect(pin.sha256 == "55701af0d51815ee335f240e48acf0959c3c23017ed3fa816e880c4a92bae581")
        #expect(pin.url(mirror: nil) == "https://dl.k8s.io/release/v1.37.2/bin/darwin/arm64/kubectl")
        #expect(!Tools.pluginNames.contains("kubectl"))
        #expect(!Tools.pins.contains { $0.name == "kubectl" })
    }
}
