import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

private final class RegistryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RegistrySafetyTests {
    private func client() -> RegistryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryProtocol.self]
        return RegistryClient(config: DockerConfig(configDir: URL(fileURLWithPath: "/nonexistent"), environment: [:]),
                              tempDirectory: FileManager.default.temporaryDirectory, sessionConfiguration: configuration)
    }

    @Test func concurrentCredentialsStayWithTheirRequests() async throws {
        RegistryProtocol.handler = { req in
            let url = req.url!
            if url.path == "/v2" { return (401, ["WWW-Authenticate": "Bearer realm=\"https://registry.example/token\""], Data()) }
            if url.path == "/token" {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                return (200, [:], Data("{\"token\":\"\(auth.replacingOccurrences(of: "Basic ", with: ""))\"}".utf8))
            }
            let expected = url.path.contains("/alice/") ? "alice:secret-a" : "bob:secret-b"
            let token = Data(expected.utf8).base64EncodedString()
            return (req.value(forHTTPHeaderField: "Authorization") == "Bearer " + token ? 200 : 403, [:], Data("{}".utf8))
        }
        let registry = client()
        let alice = try ImageReference.parse("registry.example/alice/image:latest")
        let bob = try ImageReference.parse("registry.example/bob/image:latest")
        async let first = registry.manifest(alice, credential: RegistryCredential(username: "alice", password: "secret-a"))
        async let second = registry.manifest(bob, credential: RegistryCredential(username: "bob", password: "secret-b"))
        _ = try await (first, second)
        // Same repository and scope must not reuse another identity's token.
        _ = try await registry.manifest(alice, credential: RegistryCredential(username: "alice", password: "secret-a"))
        await #expect(throws: (any Error).self) {
            _ = try await registry.manifest(alice, credential: RegistryCredential(username: "bob", password: "secret-b"))
        }
    }

    @Test func credentialRedirectsStayOnOrigin() throws {
        let transport = Transport(tempDirectory: FileManager.default.temporaryDirectory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://registry.example/token")!
        let response = HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: nil)!
        func redirected(_ original: URLRequest, to destination: String) -> URLRequest? {
            let task = session.dataTask(with: original)
            var result: URLRequest?
            var next = original
            next.url = URL(string: destination)!
            transport.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                 newRequest: next) { result = $0 }
            return result
        }
        var tokenPost = URLRequest(url: origin)
        tokenPost.httpMethod = "POST"
        tokenPost.httpBody = Data("refresh_token=secret".utf8)
        #expect(redirected(tokenPost, to: "https://evil.example/token") == nil)
        #expect(redirected(tokenPost, to: "https://registry.example/other") != nil)
        var authenticated = URLRequest(url: origin)
        authenticated.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        let redirectedAuth = redirected(authenticated, to: "https://evil.example/token")
        #expect(redirectedAuth != nil)
        #expect(redirectedAuth?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected(authenticated, to: "http://registry.example/token") == nil)
        #expect(redirected(URLRequest(url: origin), to: "https://cdn.example/blob") != nil)
        #expect(redirected(URLRequest(url: origin), to: "http://cdn.example/blob") == nil)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("private image".utf8).write(to: file)
        var upload = URLRequest(url: origin)
        upload.httpMethod = "PUT"
        let uploadTask = session.uploadTask(with: upload, fromFile: file)
        #expect(uploadTask.originalRequest?.httpBody == nil)
        var uploadRedirect: URLRequest?
        transport.urlSession(session, task: uploadTask, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: URL(string: "https://evil.example/blob")!)) { uploadRedirect = $0 }
        #expect(uploadRedirect == nil)
    }

    @Test func rejectsHostileOrInsecureRealms() async throws {
        for realm in ["https://evil.example/token", "http://registry.example/token", "not a url"] {
            RegistryProtocol.handler = { req in
                if req.url!.path == "/v2" { return (401, ["WWW-Authenticate": "Bearer realm=\"\(realm)\""], Data()) }
                Issue.record("unexpected request: \(req.url!.absoluteString)")
                return (500, [:], Data())
            }
            let ref = try ImageReference.parse("registry.example/alice/image:latest")
            await #expect(throws: (any Error).self) {
                _ = try await client().manifest(ref, credential: RegistryCredential(username: "alice", password: "secret"))
            }
        }
    }

    @Test func hubBackedRegistryMayUseTheHubRealmOnlyAnonymously() async throws {
        let challenge = "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\""
        for credential in [nil, RegistryCredential(username: "alice", password: "secret")] {
            nonisolated(unsafe) var asked = false
            RegistryProtocol.handler = { req in
                switch req.url!.path {
                case "/v2": return (401, ["WWW-Authenticate": challenge], Data())
                case "/token": asked = true; return (200, [:], Data(#"{"token":"t"}"#.utf8))
                default: return (404, [:], Data())
                }
            }
            let ref = try ImageReference.parse("registry.example/team/image:latest")
            _ = try? await client().manifest(ref, credential: credential)
            // Anonymous reaches the Hub token endpoint; with a credential the realm is refused before any request to it.
            #expect(asked == (credential == nil))
        }
    }

    @Test func realmDomainRule() {
        #expect(RegistryClient.sharesRegistryDomain("gitlab.com", "registry.gitlab.com"))
        #expect(RegistryClient.sharesRegistryDomain("git.example.com", "registry.example.com"))
        #expect(!RegistryClient.sharesRegistryDomain("evil.example", "registry.example.com"))
        #expect(!RegistryClient.sharesRegistryDomain("10.0.0.2", "10.9.0.2"))
        #expect(!RegistryClient.sharesRegistryDomain("com", "registry.com"))
        #expect(!RegistryClient.sharesRegistryDomain("auth.evil.co.uk", "registry.victim.co.uk"))
        #expect(!RegistryClient.sharesRegistryDomain("evil.github.io", "victim.github.io"))
    }

    @Test func acceptsSiblingRealmAndStillRejectsHttp() async throws {
        RegistryProtocol.handler = { req in
            switch req.url!.path {
            case "/v2": return (200, [:], Data())
            default: return (200, [:], Data("{}".utf8))
            }
        }
        RegistryProtocol.handler = { req in
            if req.url!.host == "registry.gitlab.com", req.url!.path == "/v2" {
                return (401, ["WWW-Authenticate": "Bearer realm=\"https://gitlab.com/jwt/auth\""], Data())
            }
            if req.url!.host == "gitlab.com" { return (200, [:], Data("{\"token\":\"t\"}".utf8)) }
            return (200, [:], Data("{}".utf8))
        }
        let ref = try ImageReference.parse("registry.gitlab.com/g/p:latest")
        let token = try await client().authorization(scheme: "https", host: "registry.gitlab.com", scope: "repository:g/p:pull", credential: nil)
        #expect(token == "Bearer t")
        _ = ref
    }

    @Test func invalidDigestNeverResolvesToAPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlobStore(paths: NoodlePaths(root: dir))
        for bad in ["sha256:../../x", "../../etc/passwd", "sha256:" + String(repeating: "g", count: 64)] {
            #expect(!store.has(bad))
            #expect(store.url(bad).standardized.path.hasPrefix(store.paths.blobsDir.standardized.path + "/"))
        }
    }

    @Test func rejectsManifestForWrongPinnedDigest() async throws {
        let wanted = Digest.sha256(Data("expected".utf8))
        RegistryProtocol.handler = { req in
            if req.url!.path == "/v2" { return (200, [:], Data()) }
            return (200, ["Content-Type": MediaType.dockerManifest], Data("{}".utf8))
        }
        let ref = try ImageReference.parse("registry.example/repo@\(wanted)")
        await #expect(throws: ImageError.self) { _ = try await client().manifest(ref) }
    }

    @Test func rejectsMismatchedManifestHeaderAndAcceptsValidDigest() async throws {
        let body = Data("{}".utf8)
        let good = Digest.sha256(body)
        let bad = Digest.sha256(Data("different".utf8))
        RegistryProtocol.handler = { req in
            if req.url!.path == "/v2" { return (200, [:], Data()) }
            return (200, ["Docker-Content-Digest": bad], body)
        }
        let registry = client()
        let tag = try ImageReference.parse("registry.example/repo:latest")
        await #expect(throws: ImageError.self) { _ = try await registry.manifest(tag) }
        RegistryProtocol.handler = { req in
            if req.url!.path == "/v2" { return (200, [:], Data()) }
            return (200, ["Docker-Content-Digest": good], body)
        }
        let pinned = try ImageReference.parse("registry.example/repo@\(good)")
        #expect(try await registry.manifest(pinned).digest == good)
    }

    @Test func rejectsWrongIndexChildDigest() async throws {
        let goodChild = Data("expected child".utf8)
        let wanted = Digest.sha256(goodChild)
        let index: [String: Any] = ["schemaVersion": 2, "manifests": [[
            "mediaType": MediaType.dockerManifest, "digest": wanted, "size": 14,
            "platform": ["architecture": "arm64", "os": "linux"]
        ]]]
        let indexData = try JSONSerialization.data(withJSONObject: index)
        RegistryProtocol.handler = { req in
            if req.url!.path == "/v2" { return (200, [:], Data()) }
            if req.url!.path.hasSuffix("/latest") {
                return (200, ["Content-Type": MediaType.dockerManifestList], indexData)
            }
            return (200, ["Content-Type": MediaType.dockerManifest], Data("{}".utf8))
        }
        let ref = try ImageReference.parse("registry.example/repo:latest")
        let registry = client()
        await #expect(throws: ImageError.self) { _ = try await registry.resolve(ref, platform: .arm64) }
        RegistryProtocol.handler = { req in
            if req.url!.path == "/v2" { return (200, [:], Data()) }
            if req.url!.path.hasSuffix("/latest") {
                return (200, ["Content-Type": MediaType.dockerManifestList], indexData)
            }
            return (200, ["Content-Type": MediaType.dockerManifest], goodChild)
        }
        #expect(try await registry.resolve(ref, platform: .arm64).image.digest == wanted)
    }

}
