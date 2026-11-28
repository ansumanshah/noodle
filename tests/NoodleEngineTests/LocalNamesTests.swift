import Foundation
import Testing
@testable import NoodleEngine

@Suite struct LocalNamesTests {
    func c(_ id: String, _ name: String, labels: [String: String] = [:], ip: String = "10.0.0.2", pub: [Int] = [], exp: [Int] = [], at: Double = 0) -> LocalNames.Candidate {
        .init(id: id, name: name, labels: labels, ip: ip, published: pub, exposed: exp, startedAt: Date(timeIntervalSince1970: at))
    }
    func hosts(_ t: [LocalNames.Target]) -> [String] { t.map(\.host) }

    @Test func containerNameBecomesLocalhostName() {
        let t = LocalNames.table([c("aaaaaaaaaaaa", "My_App", pub: [80])])
        #expect(hosts(t) == ["my-app.localhost", "my-app.noodle.local"])
        #expect(t[0].port == 80 && t[0].ip == "10.0.0.2")
    }

    @Test func containerWithoutWebPortHasNoName() {
        #expect(LocalNames.table([c("a", "plain")]).isEmpty)
        #expect(LocalNames.table([c("a", "db", exp: [5432])]).first?.port == 5432)   // only port: still reachable by name
        #expect(LocalNames.table([c("a", "x", ip: "", pub: [80])]).isEmpty)
    }

    @Test func webPortPrefersPublishedThenCommonWebPorts() {
        #expect(LocalNames.webPort(c("a", "x", pub: [5432, 3000], exp: [80])) == 3000)
        #expect(LocalNames.webPort(c("a", "x", exp: [5432, 8080, 9999])) == 8080)
        #expect(LocalNames.webPort(c("a", "x", labels: [LocalNames.portLabel: "4321"], pub: [80])) == 4321)
        #expect(LocalNames.webPort(c("a", "x", labels: [LocalNames.portLabel: "0"], pub: [80])) == 80)
    }

    @Test func automaticPortSkipsTLSOnlyWhenPlaintextExists() {
        #expect(LocalNames.webPort(c("a", "x", pub: [443, 8000])) == 8000)
        #expect(LocalNames.webPort(c("a", "x", exp: [8443, 5432])) == 5432)
        #expect(LocalNames.webPort(c("a", "x", exp: [443])) == 443)   // nothing else to pick
        #expect(LocalNames.webPort(c("a", "x", labels: [LocalNames.portLabel: "443"], pub: [443, 8000])) == 443)
    }

    @Test func portFallbacksAndRankingDoNotDependOnInputOrder() {
        for ports in [[5432, 9821, 9819], [9819, 5432, 9821], [9821, 9819, 5432]] {
            #expect(LocalNames.webPort(c("r", "fallback", exp: ports)) == 9819)
        }
        #expect(LocalNames.webPort(c("r", "database", exp: [6379, 5432, 3306])) == 3306)
        #expect(LocalNames.webPort(c("r", "ranked", exp: [3000, 8080, 80])) == 80)
        #expect(LocalNames.webPort(c("r", "published", pub: [5432], exp: [80])) == 5432)
    }

    @Test func htmlEscapingPreservesUnicodeAndDoesNotEscapeItsOwnOutput() {
        #expect(NameRouter.escape("&amp;<\"é\u{301}👩‍💻> &") == "&amp;amp;&lt;&quot;é\u{301}👩‍💻&gt; &amp;")
        #expect(NameRouter.escape("plain text ' / =") == "plain text ' / =")
        #expect(NameRouter.escape("") == "")
    }

    @Test func generatedAliasNeverStealsAnExistingName() {
        // "web-aaaaaa" already runs under that exact name, so the later "web" cannot take it as its alias.
        let t = LocalNames.table([c("zzzzzz111111", "web", pub: [80], at: 1), c("aaaaaa111111", "web-aaaaaa", pub: [80], at: 2),
                                  c("aaaaaa222222", "web", pub: [80], at: 3)])
        let byHost = Dictionary(uniqueKeysWithValues: t.map { ($0.host, $0.containerID) })
        #expect(byHost["web-aaaaaa.localhost"] == "aaaaaa111111")
        #expect(Set(byHost.values).count == 3)
        #expect(byHost["web.localhost"] == "zzzzzz111111")
    }

    @Test func composeServiceAndProjectNames() {
        let l = { (s: String) in ["com.docker.compose.project": "Shop", "com.docker.compose.service": s] }
        let t = LocalNames.table([c("b1", "shop-worker-1", labels: l("worker"), exp: [9000]),
                                  c("a1", "shop-web-1", labels: l("web"), exp: [80])])
        #expect(hosts(t).contains("web.shop.localhost"))
        #expect(hosts(t).contains("worker.shop.localhost"))
        #expect(hosts(t).contains("web.shop.noodle.local"))
        #expect(hosts(t).contains("worker.shop.noodle.local"))
        #expect(t.first { $0.host == "shop.noodle.local" }?.containerID == "a1")
        #expect(t.first { $0.host == "shop.localhost" }?.containerID == "a1")   // first service by name
    }

    @Test func customDomainLabel() {
        let t = LocalNames.table([c("a", "api", labels: [LocalNames.domainLabel: "Billing, admin.billing.localhost, evil.com, "], pub: [80])])
        #expect(hosts(t) == ["admin.billing.localhost", "admin.billing.noodle.local", "api.localhost", "api.noodle.local", "billing.localhost", "billing.noodle.local", "evil.com.localhost", "evil.com.noodle.local"])   // stays under .localhost
        #expect(LocalNames.customHost("bad name!") == nil)
        #expect(LocalNames.customHost("a..b") == nil)
        #expect(LocalNames.customHost("-x") == nil)
    }

    @Test func explicitBrandedCustomNameIsNotNestedUnderLocalhost() {
        #expect(LocalNames.customHost("API.Noodle.Local") == "api.noodle.local")
        #expect(LocalNames.customHost("api") == "api.localhost")
        #expect(LocalNames.customHost("api.localhost") == "api.localhost")
        #expect(LocalNames.customHost("bad..noodle.local") == nil)
        let t = LocalNames.table([c("a", "server", labels: [LocalNames.domainLabel: "api.noodle.local"], pub: [80])])
        #expect(hosts(t) == ["api.noodle.local", "server.localhost", "server.noodle.local"])
    }

    @Test func brandedCustomCollisionRetainsBothContainersAndLegacyNames() {
        let t = LocalNames.table([c("111111aaaaaa", "one", labels: [LocalNames.domainLabel: "web.noodle.local"], pub: [80], at: 1),
                                  c("222222bbbbbb", "web", pub: [8080], at: 2)])
        let byHost = Dictionary(uniqueKeysWithValues: t.map { ($0.host, $0.containerID) })
        #expect(byHost["web.noodle.local"] == "111111aaaaaa")
        #expect(byHost["web-222222.noodle.local"] == "222222bbbbbb")
        #expect(byHost["web.localhost"] == "222222bbbbbb")
    }

    @Test func collisionKeepsOldestAndSuffixesNewcomers() {
        let old = c("1111111111aa", "web", pub: [80], at: 1)
        let new = c("2222222222bb", "web", ip: "10.0.0.3", pub: [80], at: 2)
        let t = LocalNames.table([new, old])
        #expect(t.first { $0.host == "web.localhost" }?.containerID == old.id)
        #expect(t.first { $0.host == "web-222222.localhost" }?.containerID == new.id)
        #expect(t.first { $0.host == "web.noodle.local" }?.containerID == old.id)
        #expect(t.first { $0.host == "web-222222.noodle.local" }?.containerID == new.id)
        // Stop the old one: the survivor takes the plain name.
        let after = LocalNames.table([new])
        #expect(hosts(after) == ["web.localhost", "web.noodle.local"] && after[0].ip == "10.0.0.3")
    }

    @Test func restartAndPortChangeFollowTheNewAddress() {
        let before = LocalNames.table([c("a", "app", ip: "10.0.0.2", pub: [3000])])
        let after = LocalNames.table([c("a", "app", ip: "10.0.0.9", pub: [8080])])
        #expect(before[0].port == 3000 && after[0].port == 8080 && after[0].ip == "10.0.0.9")
        #expect(LocalNames.table([]).isEmpty)
    }

    @Test func hostHeaderParsing() {
        #expect(LocalNames.hostOnly("Web.Localhost:8080") == "web.localhost")
        #expect(LocalNames.hostOnly(" web.localhost. ") == "web.localhost")
        #expect(LocalNames.hostOnly("[::1]:80") == "")
    }
}

@Suite struct TLSSessionLimitTests {
    @Test func overTheLimitIsRejectedAtOnce() {
        #expect(!TLSSession.claimSlot(limit: 0))
        #expect(TLSSession.claimSlot(limit: Int.max))
        TLSSession.releaseSlot()
    }
}
