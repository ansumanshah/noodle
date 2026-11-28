import Foundation
import Testing
@testable import NoodleImages

@Suite struct ProxySettingsTests {
    @Test func exceptionsMatchHostsDomainsAndRanges() {
        let p = ProxySettings(mode: .custom, url: "http://p:3128", exceptions: ["localhost", ".corp.test", "*.lan", "10.0.0.0/8", "exact.host"])
        #expect(p.bypasses("localhost"))
        #expect(p.bypasses("a.corp.test"))
        #expect(p.bypasses("corp.test"))
        #expect(p.bypasses("x.lan"))
        #expect(p.bypasses("10.20.30.40"))
        #expect(p.bypasses("sub.exact.host"))
        #expect(!p.bypasses("11.0.0.1"))
        #expect(!p.bypasses("registry-1.docker.io"))
        #expect(ProxySettings(mode: .custom, url: "http://p:1", exceptions: ["*"]).bypasses("anything"))
    }

    @Test func redactionAndRestore() {
        let p = ProxySettings(mode: .custom, url: "http://u:secret@proxy:3128")
        #expect(p.redacted.url?.contains("secret") == false)
        #expect(p.redacted.url?.contains("u:***@") == true)
        let back = p.redacted.restoringPassword(from: p)
        #expect(back.endpoint?.password == "secret")
        let changed = ProxySettings(mode: .custom, url: "http://u:new@proxy:3128").restoringPassword(from: p)
        #expect(changed.endpoint?.password == "new")
    }

    @Test func validation() {
        #expect(throws: (any Error).self) { try ProxySettings(mode: .custom, url: "socks5://p:1").validate() }
        #expect(throws: (any Error).self) { try ProxySettings(mode: .custom, url: nil).validate() }
        #expect(throws: Never.self) { try ProxySettings(mode: .system).validate() }
    }
}
