import Foundation
import Testing
@testable import NoodleCore

@Suite struct LocalNameDomainTests {
    @Test(arguments: ["localhost", "web.localhost", "api.shop.localhost", "noodle.local", "api.noodle.local", "a-1.api.noodle.local"])
    func acceptsLocalDNSNames(_ host: String) {
        #expect(LocalNameDomain.isSupported(host))
    }

    @Test(arguments: [
        "", "example.com", "app.example", "evilnoodle.local", "noodle.local.evil.com", "localhost.evil.com",
        ".localhost", "a..localhost", "-a.localhost", "a-.localhost", "a_.localhost", "a.localhost.",
        "*.localhost", "*.noodle.local", "LOCALHOST", "A.noodle.local", "é.localhost", "127.0.0.1",
        "../a.localhost", "a/b.localhost", "a\\b.localhost", "https://a.localhost", "a.localhost:443",
        "a\n.localhost", "a\u{0}.localhost", "a.localhost\nDNS.2=evil.com"
    ])
    func rejectsForeignOrMalformedNames(_ host: String) {
        #expect(!LocalNameDomain.isSupported(host))
    }

    @Test func enforcesDNSLengths() {
        #expect(LocalNameDomain.isSupported("\(String(repeating: "a", count: 63)).localhost"))
        #expect(!LocalNameDomain.isSupported("\(String(repeating: "a", count: 64)).localhost"))
        let maximum = Array(repeating: String(repeating: "a", count: 60), count: 4).joined(separator: ".") + ".localhost"
        #expect(maximum.utf8.count == 253)
        #expect(LocalNameDomain.isSupported(maximum))
        #expect(!LocalNameDomain.isSupported("a\(maximum)"))
    }
}
