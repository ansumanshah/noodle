import Foundation
import Testing
@testable import NoodleCore
@testable import NoodleEngine

/// Mac loopback relay. The header is guest data and the deny decision guards Noodle's own listeners.
// Serialized: these tests block a cooperative thread in poll() while the relay under test needs one; run in parallel they can starve it.
@Suite(.serialized) struct HostLoopbackTests {
    private let gw: [UInt8] = [192, 168, 64, 1]

    @Test func headerParsesVersionFamilyPortAndAddress() throws {
        let r = try #require(HostLoopback.parse([1, 4, 0x15, 0x38] + gw))
        #expect(r.port == 5432)
        #expect(withUnsafeBytes(of: r.gateway) { Array($0) } == gw)
        #expect(HostLoopback.header(r) == [1, 4, 0x15, 0x38] + gw)
    }

    @Test func hostileHeadersAreRefused() {
        let bad: [[UInt8]] = [
            [], [1, 4, 0, 80], [1, 4, 0, 80] + gw + [0],  // short, long
            [0, 4, 0, 80] + gw, [2, 4, 0, 80] + gw, [255, 4, 0, 80] + gw,  // unknown versions
            [1, 6, 0, 80] + gw, [1, 0, 0, 80] + gw,  // IPv6 and unknown families
            [1, 4, 0, 0] + gw,  // port zero
        ]
        for b in bad { #expect(HostLoopback.parse(b) == nil, "\(b)") }
    }

    @Test func ordinaryPortsTryLoopbackThenTheNATAddress() {
        let r = HostLoopback.Request(port: 5432, gateway: 0x0140_a8c0)
        #expect(HostLoopback.targets(for: r, noodleOwned: false, gatewayIsMacBridge: true) == [.loopback4, .loopback6, .gateway(0x0140_a8c0)])
        #expect(HostLoopback.targets(for: r, noodleOwned: false, gatewayIsMacBridge: false) == [.loopback4, .loopback6])
    }

    @Test func noodleOwnedPortsKeepOnlyTheNATPath() {
        let r = HostLoopback.Request(port: 11345, gateway: 0x0140_a8c0)
        #expect(HostLoopback.targets(for: r, noodleOwned: true, gatewayIsMacBridge: true) == [.gateway(0x0140_a8c0)])
        // A header naming an address that is not a Mac VM bridge gets nothing at all.
        #expect(HostLoopback.targets(for: r, noodleOwned: true, gatewayIsMacBridge: false).isEmpty)
    }

    private static func claimsDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("noodle-claims-" + UUID().uuidString)
    }

    @Test func ownedPortSetCountsClaims() {
        let dir = Self.claimsDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let owned = NoodleOwnedPorts(directory: dir)
        #expect(owned.isNoodleOwned(11345, modelPort: nil))
        #expect(owned.isNoodleOwned(18080, modelPort: 18080))
        #expect(!owned.isNoodleOwned(5432, modelPort: nil))
        owned.claim(8443); owned.claim(8443)
        owned.release(8443)
        #expect(owned.contains(8443))
        owned.release(8443)
        #expect(!owned.contains(8443))
        owned.release(8443); owned.claim(0); owned.claim(70000)
        #expect(!owned.contains(8443) && !owned.contains(0))
    }

    /// Finding 2: a claim made by one daemon (one process) is seen by another daemon's relay.
    @Test func claimsAreVisibleAcrossDaemons() {
        let dir = Self.claimsDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let daemonA = NoodleOwnedPorts(directory: dir)  // this process: alive
        let daemonB = NoodleOwnedPorts(directory: dir, pid: getpid() &+ 1)
        #expect(!daemonB.contains(18090))
        daemonA.claim(18090)
        #expect(daemonB.contains(18090))
        daemonA.release(18090)
        #expect(!daemonB.contains(18090))
        // A model server claims for its own pid before execv.
        daemonA.claim(18091, forProcess: getpid())
        #expect(daemonB.contains(18091))
    }

    @Test func claimsOfDeadProcessesAreIgnoredAndPruned() throws {
        let dir = Self.claimsDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = dir.appendingPathComponent("18092")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p.appendingPathComponent("2147483646").path, contents: nil)
        #expect(!NoodleOwnedPorts(directory: dir).contains(18092))
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.path).isEmpty)
    }

    @Test func modelSessionPortIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hostlo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HostLoopback.modelSessionPort(root: root) == nil)
        let models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(#"{"id":"x","model":"m","host":"127.0.0.1","port":18080}"#.utf8).write(to: models.appendingPathComponent("session.json"))
        #expect(HostLoopback.modelSessionPort(root: root) == 18080)
        try Data(#"{"port":0}"#.utf8).write(to: models.appendingPathComponent("session.json"))
        #expect(HostLoopback.modelSessionPort(root: root) == nil)
    }

    @Test func settingDefaultsOnAndCanBeTurnedOff() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(VMSettings.self, from: Data("{}".utf8)).hostLoopback)
        #expect(try decoder.decode(VMSettings.self, from: Data(#"{"host_loopback":true}"#.utf8)).hostLoopback)
        #expect(try !decoder.decode(VMSettings.self, from: Data(#"{"host_loopback":false}"#.utf8)).hostLoopback)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hostlo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        try VMSettings(cpus: 2, memoryMiB: 1024, hostLoopback: false).save(paths: paths)
        #expect(try String(contentsOf: paths.settingsFile, encoding: .utf8).contains(#""host_loopback" : false"#))
        #expect(!VMSettings.load(paths: paths, environment: [:]).hostLoopback)
    }

    /// Finding 4: an invalid unrelated field must not turn the switch back on, and noodled refuses the file.
    @Test func undecodableSettingsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hostlo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"host_loopback":false,"cpus":"8"}"#.utf8).write(to: paths.settingsFile)
        #expect(!VMSettings.load(paths: paths, environment: [:]).hostLoopback)
        #expect(throws: SettingsFileError.self) { try VMSettings.validateFile(paths: paths) }
        try Data("not json".utf8).write(to: paths.settingsFile)
        #expect(!VMSettings.load(paths: paths, environment: [:]).hostLoopback)
        try VMSettings(cpus: 2, memoryMiB: 1024).save(paths: paths)
        try VMSettings.validateFile(paths: paths)
        try FileManager.default.removeItem(at: paths.settingsFile)
        try VMSettings.validateFile(paths: paths)  // no file: defaults, nothing to refuse
    }

    /// Finding 8: a resource form opened before the switch was turned off must not write it back on.
    @Test func savingResourcesKeepsTheSwitchOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hostlo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        var form = VMSettings(cpus: 2, memoryMiB: 1024)           // snapshot taken while on
        try VMSettings(cpus: 2, memoryMiB: 1024, hostLoopback: false).save(paths: paths)  // edited meanwhile
        form.cpus = 4
        try form.keepingFileManagedValues(from: VMSettings.load(paths: paths)).save(paths: paths)
        let saved = VMSettings.load(paths: paths, environment: [:])
        #expect(saved.cpus == 4)
        #expect(!saved.hostLoopback)
    }

    // MARK: relay, through real sockets

    @Test func relayJoinsTheGuestToAMacLoopbackService() throws {
        let (listener, port) = try Self.loopbackListener()
        defer { close(listener) }
        let guest = try Self.relay(owned: Self.freshOwned())
        defer { close(guest) }
        try Self.send(guest, HostLoopback.header(.init(port: port, gateway: 0)) + Array("ping".utf8))
        let mac = try #require(Self.accept(listener, ms: 3000), "relay never connected")
        defer { close(mac) }
        #expect(Self.receive(mac, 4) == Array("ping".utf8))
        try Self.send(mac, Array("pong".utf8))
        #expect(Self.receive(guest, 4) == Array("pong".utf8))
    }

    @Test func relayRefusesANoodleOwnedPort() throws {
        let (listener, port) = try Self.loopbackListener()
        defer { close(listener) }
        let owned = Self.freshOwned()
        owned.claim(Int(port))
        let guest = try Self.relay(owned: owned)
        defer { close(guest) }
        try Self.send(guest, HostLoopback.header(.init(port: port, gateway: 0)))
        // Owned and the header address is no Mac bridge: nothing is dialled and the guest sees the close.
        #expect(Self.receive(guest, 1, ms: 3000) == [])
        #expect(Self.accept(listener, ms: 200) == nil)
    }

    @Test func relayClosesOnAHostileHeader() throws {
        let guest = try Self.relay(owned: Self.freshOwned())
        defer { close(guest) }
        try Self.send(guest, [9, 9, 9, 9, 9, 9, 9, 9])
        #expect(Self.receive(guest, 1, ms: 3000) == [])
    }

    /// Finding 3: a Noodle listener that claims the port while the connect is pending never gets the bytes.
    @Test func relayRechecksOwnershipAfterConnecting() throws {
        let (listener, port) = try Self.loopbackListener()
        defer { close(listener) }
        let owned = Self.freshOwned()
        let r = Self.makeRelay(owned: owned)
        r.afterConnect = { p in owned.claim(Int(p)) }
        let guest = try Self.serve(r)
        defer { close(guest) }
        try Self.send(guest, HostLoopback.header(.init(port: port, gateway: 0)) + Array("secret".utf8))
        #expect(Self.receive(guest, 1, ms: 3000) == [], "the guest side must be closed")
        if let mac = Self.accept(listener, ms: 500) {
            defer { close(mac) }
            #expect(Self.receive(mac, 6, ms: 1000) == [], "the claimed listener received relayed bytes")
        }
    }

    /// Finding 6: a Mac service that never closes its side must not keep a slot once the VM stopped.
    @Test func closeAllFreesSlotsWhenTheVMStops() throws {
        let (listener, port) = try Self.loopbackListener()
        defer { close(listener) }
        let r = Self.makeRelay(owned: Self.freshOwned())
        let guest = try Self.serve(r)
        defer { close(guest) }
        try Self.send(guest, HostLoopback.header(.init(port: port, gateway: 0)))
        let mac = try #require(Self.accept(listener, ms: 3000))
        defer { close(mac) }                 // held open: the service ignores EOF
        shutdown(guest, SHUT_WR)              // the guest half-closes, as a stopping VM does first
        #expect(Self.receive(mac, 1, ms: 1000) == [])
        #expect(r.openRelays == 1, "half-close alone keeps the relay, as TCP needs")
        r.closeAll()
        #expect(r.openRelays == 0)
        #expect(Self.receive(guest, 1, ms: 3000) == [])
        #expect(Self.receive(mac, 1, ms: 3000) == [], "the Mac side is closed too")
    }

    // MARK: helpers

    private static func freshOwned() -> NoodleOwnedPorts { NoodleOwnedPorts(directory: claimsDir()) }

    private static func makeRelay(owned: NoodleOwnedPorts) -> HostLoopbackRelay {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hostlo-" + UUID().uuidString)
        return HostLoopbackRelay(paths: NoodlePaths(root: root), owned: owned)
    }

    private static func serve(_ r: HostLoopbackRelay) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        r.serve(guestFD: pair[0])
        return pair[1]
    }

    private static func relay(owned: NoodleOwnedPorts) throws -> Int32 { try serve(makeRelay(owned: owned)) }

    private static func loopbackListener() throws -> (Int32, UInt16) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && listen(s, 4) == 0 && getsockname(s, $0, &len) == 0 }
        }
        guard s >= 0, ok else { close(s); throw POSIXError(.EADDRNOTAVAIL) }
        return (s, UInt16(bigEndian: a.sin_port))
    }

    private static func wait(_ fd: Int32, ms: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, ms) > 0
    }

    private static func accept(_ listener: Int32, ms: Int32) -> Int32? {
        guard wait(listener, ms: ms) else { return nil }
        let c = Darwin.accept(listener, nil, nil)
        return c >= 0 ? c : nil
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw POSIXError(.EIO) }
    }

    /// Up to `count` bytes; an empty array means the peer closed (or nothing arrived in time).
    private static func receive(_ fd: Int32, _ count: Int, ms: Int32 = 3000) -> [UInt8] {
        var out: [UInt8] = []
        while out.count < count, wait(fd, ms: ms) {
            var buf = [UInt8](repeating: 0, count: count - out.count)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
    }
}
