import Foundation
import Testing
@testable import NoodleCore

/// Host and guest agree on the vsock ports in docs/architecture/protocol.md.
@Suite struct VsockPortContractTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func zigConstant(_ name: String, in text: String) -> UInt32? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("const \(name) ") }),
              let value = line.split(separator: "=").dropFirst().first?.split(separator: ";").first else { return nil }
        return UInt32(value.trimmingCharacters(in: .whitespaces))
    }

    @Test func portsFormOneBlockWithHostListenersBelowGuestListeners() {
        let ports = [NoodleWire.sshAgentPort, NoodleWire.readyPort, NoodleWire.controlPort, NoodleWire.streamPort]
        #expect(ports == Array(1030...1033))
        #expect(Set(ports).count == ports.count)
    }

    @Test func guestAgentUsesTheSamePorts() throws {
        let main = try Self.source("guest/agent/src/main.zig")
        #expect(Self.zigConstant("PORT_CTL", in: main) == NoodleWire.controlPort)
        #expect(Self.zigConstant("PORT_STREAM", in: main) == NoodleWire.streamPort)
        #expect(Self.zigConstant("PORT_READY", in: main) == NoodleWire.readyPort)
        #expect(Self.zigConstant("host_port", in: try Self.source("guest/agent/src/sshagent.zig")) == NoodleWire.sshAgentPort)
        #expect(Self.zigConstant("docker_port", in: try Self.source("guest/agent/src/sshagent.zig")) == NoodleWire.dockerApiPort)
    }

    @Test func machineHelperUsesTheSamePorts() throws {
        let wire = try Self.source("Sources/noodle-machine/RawWire.swift")
        #expect(wire.contains("let rawControlPort: UInt32 = \(NoodleWire.controlPort)\n"))
        #expect(wire.contains("let rawStreamPort: UInt32 = \(NoodleWire.streamPort)\n"))
    }
}
