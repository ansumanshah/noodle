import Foundation
import Testing
@testable import NoodleCore

@Suite struct ImportSupportTests {
    @Test func namingPolicies() {
        let taken: Set<String> = ["db", "db-imported"]
        let exists = { taken.contains($0) }
        #expect(ImportNaming.decide("web", exists: exists, policy: .skip) == .create("web"))
        #expect(ImportNaming.decide("db", exists: exists, policy: .skip) == .skip)
        #expect(ImportNaming.decide("db", exists: exists, policy: .overwrite) == .replace("db"))
        #expect(ImportNaming.decide("db", exists: exists, policy: .rename) == .create("db-imported-2"))
    }

    @Test func endpoints() throws {
        #expect(try ImportNaming.socketPath(host: "unix:///a/b.sock") == "/a/b.sock")
        #expect(throws: ImportNaming.Malformed.self) { try ImportNaming.socketPath(host: "tcp://1.2.3.4:2375") }
        let meta = Data(#"{"Name":"orbstack","Endpoints":{"docker":{"Host":"unix:///x.sock"}}}"#.utf8)
        #expect(ImportNaming.contextHost(metaJSON: meta)?.host == "unix:///x.sock")
    }

    @Test func podmanSocketResolution() {
        let home = "/Users/me"
        let fromInspect = ImportNaming.podmanSocket(inspectOutput: "/var/folders/x/podman/podman-machine-default-api.sock\n", home: home, tmpDir: nil, exists: { _ in false })
        #expect(fromInspect == "/var/folders/x/podman/podman-machine-default-api.sock")
        // several machines: prefer the first socket that exists
        let two = "/a/one.sock\n/a/two.sock\n"
        #expect(ImportNaming.podmanSocket(inspectOutput: two, home: home, tmpDir: nil, exists: { $0 == "/a/two.sock" }) == "/a/two.sock")
        // junk output falls through to the default folder
        let fallback = home + "/.local/share/containers/podman/machine/podman.sock"
        #expect(ImportNaming.podmanSocket(inspectOutput: "Error: no machine", home: home, tmpDir: nil, exists: { $0 == fallback }) == fallback)
        #expect(ImportNaming.podmanSocket(inspectOutput: nil, home: home, tmpDir: nil, exists: { $0 == fallback }) == fallback)
        let tmpSock = "/var/folders/t/podman/podman-machine-default-api.sock"
        #expect(ImportNaming.podmanSocket(inspectOutput: nil, home: home, tmpDir: "/var/folders/t/", exists: { $0 == tmpSock }) == tmpSock)
        #expect(ImportNaming.podmanSocket(inspectOutput: nil, home: home, tmpDir: nil, exists: { _ in false }) == nil)
    }

    @Test func runningPodmanMachineByName() {
        func pick(_ json: String) -> String? { ImportNaming.runningPodmanMachine(listJSON: Data(json.utf8)) }
        // a stopped default and a running named machine: the named one is chosen
        #expect(pick(#"[{"Name":"podman-machine-default","Default":true,"Running":false},{"Name":"noodle-bench","Default":false,"Running":true}]"#) == "noodle-bench")
        // the default marker never leaks into the name
        #expect(pick(#"[{"Name":"podman-machine-default*","Default":true,"Running":true}]"#) == "podman-machine-default")
        // two running: the default wins
        #expect(pick(#"[{"Name":"a","Running":true},{"Name":"b","Default":true,"Running":true}]"#) == "b")
        #expect(pick(#"[{"Name":"a","Running":false}]"#) == nil)
        #expect(pick("[]") == nil)
        #expect(pick("not json") == nil)
        // the named machine's inspect output feeds the socket resolver
        #expect(ImportNaming.podmanSocket(inspectOutput: "/t/podman/noodle-bench-api.sock\n", home: "/h", tmpDir: nil, exists: { _ in false }) == "/t/podman/noodle-bench-api.sock")
    }

    @Test func boundedProbeStopsHungAndCancelledChildren() {
        #expect(runBounded("/bin/echo", ["hi"], timeout: 5, cancelled: { false }) == "hi\n")
        #expect(runBounded("/usr/bin/false", [], timeout: 5, cancelled: { false }) == nil)
        let start = Date()
        #expect(runBounded("/bin/sleep", ["30"], timeout: 0.3, cancelled: { false }) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        let cancelStart = Date()
        #expect(runBounded("/bin/sleep", ["30"], timeout: 30, cancelled: { true }) == nil)
        #expect(Date().timeIntervalSince(cancelStart) < 5)
    }

    private func block(_ s: String, size: Int) -> Data {
        var d = Data(count: 512)
        func put(_ text: String, at i: Int) { d.replaceSubrange(i..<i + text.utf8.count, with: Array(text.utf8)) }
        put(s, at: 0)
        put("0000644\0", at: 100); put("0001750\0", at: 108); put("0001750\0", at: 116)
        put(String(format: "%011o\0", size), at: 124)
        d[156] = UInt8(ascii: "0")
        return d
    }

    private func tar(_ files: [(String, String)]) -> Data {
        var out = Data()
        for (name, body) in files {
            out += block(name, size: body.utf8.count)
            out += Data(body.utf8)
            out += Data(count: (512 - body.utf8.count % 512) % 512)
        }
        return out + Data(count: 1024)
    }

    @Test func manifestDetectsContentAndOwnership() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.tar"), b = dir.appendingPathComponent("b.tar")
        try tar([("v/x", "hello"), ("v/y", "world")]).write(to: a)
        try tar([("./v/x", "hello"), ("v/y", "WORLD")]).write(to: b)
        let ma = try TarManifest.manifest(of: a), mb = try TarManifest.manifest(of: b)
        #expect(ma["v/x"]?.hasPrefix("0 644 1000 1000 5 ") == true)
        #expect(ma["v/x"] == mb["v/x"])
        #expect(TarManifest.differences(ma, mb) == ["differs: v/y"])
        #expect(TarManifest.differences(ma, ma).isEmpty)
    }

    @Test func oversizedExtendedHeaderIsMalformed() throws {
        var header = [UInt8](repeating: 0, count: 512)
        header[156] = UInt8(ascii: "x")
        Array("00000000000".utf8).enumerated().forEach { header[124 + $0.offset] = $0.element }
        Array("77777777".utf8).enumerated().forEach { header[124 + $0.offset] = $0.element }   // 8 MiB
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pax-\(UUID()).tar")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(header).write(to: url)
        #expect(throws: (any Error).self) { try TarManifest.manifest(of: url) }
    }
}
