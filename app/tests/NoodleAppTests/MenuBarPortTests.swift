import Foundation
import Testing
@testable import NoodleApp

@Suite struct MenuBarPortTests {
    @Test func endpointsKeepBindingsProtocolsAndSchemes() {
        let mappings = [
            PortMapping(ip: "127.0.0.2", privatePort: 443, publicPort: 8080, type: "tcp"),
            PortMapping(ip: "127.0.0.3", privatePort: 80, publicPort: 8080, type: "tcp"),
            PortMapping(ip: "127.0.0.2", privatePort: 80, publicPort: 8080, type: "udp"),
            PortMapping(ip: "::1", privatePort: 5432, publicPort: 5432, type: "tcp"),
        ]
        let container = ContainerSummary(id: "web", names: ["/web"], image: "app", state: "running",
                                         status: "Up", created: 0, ports: mappings, labels: [:])
        let ports = MenuBarSummary.make(containers: [container], machines: [], isUp: true).ports
        #expect(ports.count == 4)
        #expect(Set(ports.map(\.id)).count == 4)
        #expect(ports.first?.address == "[::1]:5432")
        #expect(ports.first?.copies == true)
        #expect(ports[1].endpoint.url?.absoluteString == "https://127.0.0.2:8080")
        #expect(ports[2].endpoint.url?.absoluteString == "http://127.0.0.3:8080")
        #expect(ports[3].copies)
        #expect(ports[3].endpoint.url == nil)
        #expect(ports[3].title.contains("/udp"))
    }

    @Test func wildcardEndpointsCollapseAcrossContainers() {
        func container(_ id: String, ip: String) -> ContainerSummary {
            ContainerSummary(id: id, names: ["/" + id], image: "app", state: "running", status: "Up", created: 0,
                             ports: [PortMapping(ip: ip, privatePort: 80, publicPort: 8080, type: "tcp")], labels: [:])
        }
        let summary = MenuBarSummary.make(containers: [container("v4", ip: "0.0.0.0"), container("v6", ip: "::")],
                                          machines: [], isUp: true)
        #expect(summary.totalPorts == 1)
        #expect(summary.ports.first?.address == "localhost:8080")
    }
}
