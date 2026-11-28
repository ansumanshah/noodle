import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

private final class PullRaceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: (type: String, data: Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let key = Self.files.keys.first { path.hasSuffix($0) }
        let file = key.flatMap { Self.files[$0] }
        var headers = ["Content-Type": file?.type ?? "text/plain"]
        if let file { headers["Docker-Content-Digest"] = Digest.sha256(file.data) }
        let status = file != nil || !path.contains("/t/img") ? 200 : 404
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if let file, request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: file.data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct PullTagRaceTests {
    /// Two pulls of one image under different tags both await the unpack hook; neither may drop the other's tag.
    @Test func concurrentPullsOfOneImageKeepEveryTag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-pullrace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        try paths.ensureDirectories()
        let layer = Data(repeating: 1, count: 4096)
        let layerDigest = Digest.sha256(layer)
        let config = Data(#"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":["\#(layerDigest)"]}}"#.utf8)
        let cfgDigest = Digest.sha256(config)
        let manifest = Data(#"""
        {"schemaVersion":2,"mediaType":"\#(MediaType.dockerManifest)","config":{"mediaType":"\#(MediaType.dockerConfig)","digest":"\#(cfgDigest)","size":\#(config.count)},"layers":[{"mediaType":"\#(MediaType.ociLayerTar)","digest":"\#(layerDigest)","size":\#(layer.count)}]}
        """#.utf8)
        PullRaceProtocol.files = [
            "/blobs/\(layerDigest)": ("application/octet-stream", layer),
            "/blobs/\(cfgDigest)": ("application/octet-stream", config),
            "/manifests/a": (MediaType.dockerManifest, manifest),
            "/manifests/b": (MediaType.dockerManifest, manifest),
            "/manifests/c": (MediaType.dockerManifest, manifest),
        ]
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PullRaceProtocol.self]
        let client = RegistryClient(config: DockerConfig(configDir: URL(fileURLWithPath: "/nonexistent"), environment: [:]),
                                    tempDirectory: paths.tmpDir, sessionConfiguration: cfg)
        let store = ImageStore(paths: paths, registry: client)
        _ = try await store.pull("127.0.0.1:5000/t/img:a", progress: { _ in })
        let slow: @Sendable (LayerRef) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(100)) }
        async let b = store.pull("127.0.0.1:5000/t/img:b", progress: { _ in }, onLayer: slow)
        async let c = store.pull("127.0.0.1:5000/t/img:c", progress: { _ in }, onLayer: slow)
        _ = try await (b, c)
        let tags = try #require(await store.get(id: cfgDigest)).repoTags
        #expect(Set(tags) == ["127.0.0.1:5000/t/img:a", "127.0.0.1:5000/t/img:b", "127.0.0.1:5000/t/img:c"])
    }
}
