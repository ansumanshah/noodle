import Foundation
import Testing
@testable import NoodleEngine

@Suite struct HostNamesTests {
    @Test func validatesDNSLabels() {
        for ok in ["myapp", "api.myapp", "a-b", "x1", String(repeating: "a", count: 63)] { #expect(LocalNames.validHostLabel(ok), "\(ok)") }
        for bad in ["", "My", "-a", "a-", "a..b", "a_b", "a b", "é", "app.localhost", "app.noodle.local", "localhost",
                    String(repeating: "a", count: 64), String(repeating: "a.", count: 125) + "a"] {
            #expect(!LocalNames.validHostLabel(bad), "\(bad)")
        }
        #expect(LocalNames.hostNames("api.myapp") == ["api.myapp.localhost", "api.myapp.noodle.local"])
    }

    @Test func containerNameWinsClash() {
        let web = LocalNames.Target(host: "web.localhost", containerID: "abc", ip: "10.0.0.2", port: 80)
        let hostRoute = LocalNames.Target(host: "mine.localhost", containerID: "host:mine", ip: "127.0.0.1", port: 3000, kind: "host")
        #expect(LocalNames.clash("web", with: [web, hostRoute]) == "web.localhost")
        #expect(LocalNames.clash("mine", with: [web, hostRoute]) == nil)
        #expect(LocalNames.clash("other", with: [web]) == nil)
    }

    @Test func jsonUnlessHTMLIsPreferred() {
        #expect(!NameRouter.prefersHTML(nil))
        #expect(!NameRouter.prefersHTML("*/*"))
        #expect(!NameRouter.prefersHTML("application/json"))
        #expect(!NameRouter.prefersHTML("application/json, text/html;q=0.5"))
        #expect(NameRouter.prefersHTML("text/html"))
        #expect(NameRouter.prefersHTML("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"))
        #expect(!NameRouter.prefersHTML("text/html;q=0"))
    }

    @Test func loopHeaderIsDetectedAndAddedOnce() {
        let raw = "GET / HTTP/1.1\r\nHost: Demo.localhost:8080\r\nAccept: text/html\r\n\r\n"
        let parsed = NameRouter.RequestHead(raw)
        #expect(parsed.host == "demo.localhost" && parsed.accept == "text/html" && !parsed.hop)
        let marked = String(decoding: NameRouter.markHop(Data(raw.utf8)), as: UTF8.self)
        #expect(marked.hasPrefix("GET / HTTP/1.1\r\nNoodle-Hop: 1\r\nHost:"))
        #expect(NameRouter.RequestHead(marked).hop)
    }

    @Test func jsonBodyHasTheThreeFields() throws {
        let object = try JSONSerialization.jsonObject(with: Data(NameRouter.jsonBody(error: "e", name: "n\"x", hint: "h").utf8)) as? [String: String]
        #expect(object == ["error": "e", "name": "n\"x", "hint": "h"])
    }
}
