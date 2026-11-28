import Foundation
import Testing
@testable import NoodleApp

@Suite struct LocalNameTableTests {
    @Test func decodesDaemonReplyAndLinksRunningContainers() {
        let json = Data(#"{"enabled":true,"port":8080,"names":[{"host":"web.localhost","containerID":"abc123def456","ip":"10.0.0.2","port":80}]}"#.utf8)
        let table = LocalNameTable.decode(json)
        let web = ContainerSummary(id: "abc123def456" + "00", names: ["/web"], image: "x", state: "running", status: "Up", created: 0, ports: [], labels: [:])
        #expect(table.link(for: web)?.url.absoluteString == "http://web.localhost:8080")
        var stopped = web; stopped.state = "exited"
        #expect(table.link(for: stopped) == nil)
        #expect(LocalNameTable.decode(Data(#"{"enabled":false,"names":[]}"#.utf8)).entries.isEmpty)
    }

    @Test func demoContainersShowNames() async throws {
        let demo = DemoDocker(mode: .normal)
        let table = try await demo.localNames()
        let list = try await demo.containers()
        let hosts = list.compactMap { table.link(for: $0)?.host }.sorted()
        #expect(hosts == ["api.localhost", "minio.localhost", "open-webui.localhost", "web.localhost"])
    }
}
