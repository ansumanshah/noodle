import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

private final class HardeningProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))!
    nonisolated(unsafe) static var tokenFetches = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/token" { Self.tokenFetches += 1 }
        let (status, headers, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RegistryHardeningTests {
    private let blob = Data(repeating: 7, count: 100_000)
    private var digest: String { Digest.sha256(blob) }

    private func rig(host: String) throws -> (RegistryClient, BlobStore, ImageReference, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hard-\(UUID().uuidString)")
        let paths = NoodlePaths(root: root)
        try paths.ensureDirectories()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HardeningProtocol.self]
        HardeningProtocol.tokenFetches = 0
        let client = RegistryClient(config: DockerConfig(configDir: URL(fileURLWithPath: "/nonexistent"), environment: [:]),
                                    tempDirectory: paths.tmpDir, sessionConfiguration: cfg)
        return (client, BlobStore(paths: paths), try ImageReference.parse("\(host)/t/blob:1"), root)
    }

    @Test func oversizedBlobStreamFails() async throws {
        let (client, store, ref, root) = try rig(host: "127.0.0.1:5000"); defer { try? FileManager.default.removeItem(at: root) }
        HardeningProtocol.handler = { [blob] req in
            req.url!.path == "/v2/" ? (200, [:], Data()) : (200, [:], blob + blob)
        }
        await #expect(throws: (any Error).self) {
            try await client.fetchBlob(ref, digest: digest, expectedSize: Int64(blob.count), into: store)
        }
        #expect(!store.has(digest))
    }

    @Test func tokenIsReusedAcrossBlobsAndClearedOn401() async throws {
        let (client, store, ref, root) = try rig(host: "registry.example"); defer { try? FileManager.default.removeItem(at: root) }
        let other = Data(repeating: 9, count: 5_000)
        let otherDigest = Digest.sha256(other)
        nonisolated(unsafe) var rejectOnce = false
        HardeningProtocol.handler = { [blob] req in
            let path = req.url!.path
            if path == "/v2" || path == "/v2/" { return (401, ["WWW-Authenticate": "Bearer realm=\"https://registry.example/token\",service=\"r\""], Data()) }
            if path == "/token" { return (200, [:], Data("{\"token\":\"t\",\"expires_in\":300}".utf8)) }
            if rejectOnce { rejectOnce = false; return (401, [:], Data()) }
            return (200, [:], path.hasSuffix(otherDigest) ? other : blob)
        }
        try await client.fetchBlob(ref, digest: digest, expectedSize: nil, into: store)
        try await client.fetchBlob(ref, digest: otherDigest, expectedSize: nil, into: store)
        #expect(HardeningProtocol.tokenFetches == 1, "got \(HardeningProtocol.tokenFetches)")
        let third = Data(repeating: 3, count: 100)
        let thirdDigest = Digest.sha256(third)
        HardeningProtocol.handler = { req in
            let path = req.url!.path
            if path == "/v2" || path == "/v2/" { return (401, ["WWW-Authenticate": "Bearer realm=\"https://registry.example/token\",service=\"r\""], Data()) }
            if path == "/token" { return (200, [:], Data("{\"token\":\"t\",\"expires_in\":300}".utf8)) }
            if rejectOnce { rejectOnce = false; return (401, [:], Data()) }
            return (200, [:], third)
        }
        rejectOnce = true
        try await client.fetchBlob(ref, digest: thirdDigest, expectedSize: nil, into: store)
        #expect(HardeningProtocol.tokenFetches == 2, "got \(HardeningProtocol.tokenFetches)")
    }
}
