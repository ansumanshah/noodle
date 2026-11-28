import Foundation
import Testing
@testable import NoodleCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var lastAuth: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastAuth = request.value(forHTTPHeaderField: "Authorization")
        let r = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct BrowserSignInTests {
    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    @Test func tokenPagesCarryTheRightScopes() {
        #expect(BrowserSignIn.Provider.github.tokenPage?.absoluteString == "https://github.com/settings/tokens/new?scopes=read:packages&description=Noodle")
        #expect(BrowserSignIn.Provider.huggingFace.tokenPage?.absoluteString == "https://huggingface.co/settings/tokens/new?tokenType=read")
        #expect(BrowserSignIn.Provider.ecr.tokenPage == nil)
        #expect(BrowserSignIn.Provider.github.registry == "ghcr.io")
    }

    @Test func gitOptionAddsRepoScopeAndSafeCredential() {
        #expect(BrowserSignIn.Provider.githubTokenPage(git: true).absoluteString.contains("scopes=read:packages,repo"))
        #expect(!BrowserSignIn.Provider.githubTokenPage(git: false).absoluteString.contains("repo"))
        #expect(BrowserSignIn.Provider.gitCredential(user: "a", token: "t") == "protocol=https\nhost=github.com\nusername=a\npassword=t\n\n")
        #expect(BrowserSignIn.Provider.gitCredential(user: "a", token: "t\nhost=evil") == nil)
    }

    @Test func validTokenReturnsAccountAndSendsBearer() async throws {
        StubProtocol.reply = (200, #"{"login":"octo"}"#)
        let name = try await BrowserSignIn.validate("  ghp_abc \n", for: .github, session: session)
        #expect(name == "octo" && StubProtocol.lastAuth == "Bearer ghp_abc")
        StubProtocol.reply = (200, #"{"name":"demo"}"#)
        #expect(try await BrowserSignIn.validate("hf_x", for: .huggingFace, session: session) == "demo")
    }

    @Test func rejectedAndMalformedTokensThrow() async {
        StubProtocol.reply = (401, #"{"message":"bad"}"#)
        await #expect(throws: BrowserSignIn.Failure.self) { try await BrowserSignIn.validate("nope", for: .github, session: session) }
        await #expect(throws: BrowserSignIn.Failure.self) { try await BrowserSignIn.validate("two words", for: .huggingFace, session: session) }
        await #expect(throws: BrowserSignIn.Failure.self) { try await BrowserSignIn.validate("", for: .huggingFace, session: session) }
    }

    @Test func huggingFaceTokenFileIsPrivateAndEnvWins() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HF_HOME": home.path]
        #expect(BrowserSignIn.huggingFaceToken(environment: env) == nil)
        try BrowserSignIn.saveHuggingFaceToken(" hf_secret\n", environment: env)
        #expect(BrowserSignIn.huggingFaceToken(environment: env) == "hf_secret")
        let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("token").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(BrowserSignIn.huggingFaceToken(environment: env.merging(["HF_TOKEN": "hf_env"]) { $1 }) == "hf_env")
    }
}
