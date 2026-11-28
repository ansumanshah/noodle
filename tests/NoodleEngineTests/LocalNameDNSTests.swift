import Testing
import Foundation
@testable import NoodleEngine

@Suite(.serialized) struct LocalNameDNSTests {
    @Test func ipv4OnlyRecordsNeverInventAnIPv6Destination() {
        #expect(LocalNameDNS.addressRecords(ipv6: false) == [.init(type: 1, bytes: [127, 0, 0, 1])])
    }

    @Test func dualListenerRecordsIncludeGenuineIPv6Loopback() {
        #expect(LocalNameDNS.addressRecords(ipv6: true) == [
            .init(type: 1, bytes: [127, 0, 0, 1]),
            .init(type: 28, bytes: Array(repeating: 0, count: 15) + [1])
        ])
    }

    @Test func listenerAcceptsBothLoopbackFamiliesAtItsSelectedPort() throws {
        let listener = try NameListener(port: 0, scope: .loopback, label: "app.noodle.tests.dual-listener") { Darwin.close($0) }
        defer { listener.stop() }
        for family in [AF_INET, AF_INET6] {
            let client = socket(family, SOCK_STREAM, 0)
            try #require(client >= 0)
            defer { Darwin.close(client) }
            let result: Int32
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(listener.port).bigEndian
                address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            } else {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = UInt16(listener.port).bigEndian
                address.sin6_addr = in6addr_loopback
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
            #expect(result == 0)
            #expect(NameListener.isLoopback(peer: client))
        }
    }

    @Test func occupiedIPv6CompanionRollsBackIPv4Binding() throws {
        let occupied = socket(AF_INET6, SOCK_STREAM, 0)
        try #require(occupied >= 0)
        defer { Darwin.close(occupied) }
        var one: Int32 = 1
        try #require(setsockopt(occupied, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(occupied, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        try #require(bound == 0 && listen(occupied, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let selected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(occupied, $0, &length) }
        }
        try #require(selected == 0)
        let port = Int(UInt16(bigEndian: address.sin6_port))
        do {
            let unexpected = try NameListener(port: port, scope: .loopback, label: "app.noodle.tests.occupied-v6") { Darwin.close($0) }
            unexpected.stop()
            Issue.record("Listener must fail when its IPv6 companion port is occupied.")
        } catch { }
        let ipv4 = socket(AF_INET, SOCK_STREAM, 0)
        try #require(ipv4 >= 0)
        defer { Darwin.close(ipv4) }
        var available = sockaddr_in()
        available.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        available.sin_family = sa_family_t(AF_INET)
        available.sin_port = UInt16(port).bigEndian
        available.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let rebound = withUnsafePointer(to: &available) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ipv4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(rebound == 0)
    }

    @Test func onlyCanonicalBrandedRoutesEnterLocalDNS() {
        let input: Set<String> = ["web.noodle.local", "api.shop.noodle.local", "web.localhost", "localhost", "noodle.local",
                                  "evil.com", "web.noodle.local.evil.com", "bad..noodle.local", "UPPER.noodle.local",
                                  "*.noodle.local", "-bad.noodle.local", "web.noodle.local."]
        #expect(LocalNameDNS.hostsToRegister(input) == ["web.noodle.local", "api.shop.noodle.local"])
    }

    @Test func unsupportedNamesNeverOpenAConnectionAndStopIsFinal() {
        let dns = LocalNameDNS()
        dns.enableIPv6()
        dns.update(hosts: ["web.localhost", "example.com"])
        #expect(dns.status == LocalNameDNSStatus(registered: [], pending: [], errors: [:]))
        dns.stop()
        dns.stop()
        dns.update(hosts: ["web.noodle.local"])
        #expect(dns.status == LocalNameDNSStatus(registered: [], pending: [], errors: [:]))
    }

    @Test func removedRegistrationCannotBeReturnedAsReady() async {
        let dns = LocalNameDNS()
        dns.stop()
        do {
            try await dns.waitUntilRegistered("web.noodle.local")
            Issue.record("A stopped registration must fail instead of returning a usable URL.")
        } catch { }
    }
}
