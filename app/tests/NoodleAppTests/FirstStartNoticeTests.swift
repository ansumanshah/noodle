import Foundation
import Testing
@testable import NoodleApp

@MainActor
struct FirstStartNoticeTests {
    @Test func firstNamedStartPersistsDismissal() throws {
        let suite = "first-start-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = try JSONDecoder().decode(DockerEvent.self, from: Data(
            #"{"Type":"container","Action":"start","Actor":{"ID":"1","Attributes":{"name":"compose-web-1"}}}"#.utf8))
        let notice = FirstStartNotice(defaults: defaults, hasAsk: true)
        notice.observe(start)
        #expect(notice.containerName == "compose-web-1")
        notice.dismiss()
        let relaunched = FirstStartNotice(defaults: defaults, hasAsk: true)
        relaunched.observe(start)
        #expect(relaunched.containerName == nil)
        // Without a repository to open there is nothing to ask, so the card never shows.
        let silent = FirstStartNotice(defaults: try #require(UserDefaults(suiteName: suite + "-silent")), hasAsk: false)
        silent.observe(start)
        #expect(silent.containerName == nil)
    }

    @Test func publicRepositoryLinkMustBeOnGitHub() {
        #expect(FirstStartNotice.repositoryURL("https://github.com/owner/repo") != nil)
        #expect(FirstStartNotice.repositoryURL("https://github.com/owner") == nil)
        #expect(FirstStartNotice.repositoryURL("https://github.com.evil.example/owner/repo") == nil)
    }
}
