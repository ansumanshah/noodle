import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

/// Registry stand-in that honours, ignores or refuses `Range`, and can cut a transfer short.
private final class BlobProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data, Bool))!   // status, headers, body, cutAfterBody
    nonisolated(unsafe) static var ranges: [String?] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
        let (status, headers, body, cut) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if cut { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) } else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct PartialBlobTests {
    private let blob = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    private var digest: String { Digest.sha256(blob) }

    private func rig() throws -> (RegistryClient, BlobStore, ImageReference, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-partial-\(UUID().uuidString)")
        let paths = NoodlePaths(root: root)
        try paths.ensureDirectories()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [BlobProtocol.self]
        BlobProtocol.ranges = []
        let client = RegistryClient(config: DockerConfig(configDir: URL(fileURLWithPath: "/nonexistent"), environment: [:]),
                                    tempDirectory: paths.tmpDir, sessionConfiguration: cfg)
        return (client, BlobStore(paths: paths), try ImageReference.parse("127.0.0.1:5000/t/blob:1"), root)
    }

    private func plant(_ store: BlobStore, _ bytes: Data) throws {
        try FileManager.default.createDirectory(at: store.partialDir, withIntermediateDirectories: true)
        try bytes.write(to: store.partialURL(digest))
    }

    private func honouring(_ req: URLRequest) -> (Int, [String: String], Data, Bool) {
        if req.url!.path == "/v2/" { return (200, [:], Data(), false) }
        guard let r = req.value(forHTTPHeaderField: "Range"), let from = Int(r.dropFirst(6).dropLast()) else { return (200, [:], blob, false) }
        return (206, ["Content-Range": "bytes \(from)-\(blob.count - 1)/\(blob.count)"], blob.suffix(from: from), false)
    }

    @Test func resumesFromPartialWithRange() async throws {
        let (client, store, ref, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        try plant(store, blob.prefix(120_000))
        BlobProtocol.handler = { [self] in honouring($0) }
        try await client.fetchBlob(ref, digest: digest, expectedSize: Int64(blob.count), into: store)
        #expect(BlobProtocol.ranges.compactMap { $0 }.contains("bytes=120000-"))
        #expect(try store.read(digest) == blob)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(digest).path))
    }

    @Test func serverIgnoringRangeRestartsCleanly() async throws {
        let (client, store, ref, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        try plant(store, blob.prefix(120_000))
        BlobProtocol.handler = { [blob] _ in (200, [:], blob, false) }
        try await client.fetchBlob(ref, digest: digest, expectedSize: nil, into: store)
        #expect(try store.read(digest) == blob)
    }

    @Test func rangeNotSatisfiableDiscardsPartial() async throws {
        let (client, store, ref, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        try plant(store, blob.prefix(120_000))
        BlobProtocol.handler = { [blob] req in req.value(forHTTPHeaderField: "Range") != nil ? (416, [:], Data(), false) : (200, [:], blob, false) }
        try await client.fetchBlob(ref, digest: digest, expectedSize: nil, into: store)
        #expect(try store.read(digest) == blob)
    }

    @Test func corruptPartialIsRefetchedWhole() async throws {
        let (client, store, ref, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        var bad = Data(blob.prefix(120_000)); bad[500] ^= 0xFF
        try plant(store, bad)
        BlobProtocol.handler = { [self] in honouring($0) }
        try await client.fetchBlob(ref, digest: digest, expectedSize: Int64(blob.count), into: store)
        #expect(BlobProtocol.ranges.compactMap { $0 }.count == 1)       // one ranged try, then a plain refetch
        #expect(BlobProtocol.ranges.last! == nil)
        #expect(try store.read(digest) == blob)
    }

    @Test func wrongContentIsNeverPromoted() async throws {
        let (client, store, ref, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        BlobProtocol.handler = { _ in (200, [:], Data(repeating: 7, count: 1000), false) }
        await #expect(throws: ImageError.self) { try await client.fetchBlob(ref, digest: digest, expectedSize: nil, into: store) }
        #expect(!store.has(digest))
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(digest).path))
    }

    /// A drop before any byte arrives is retried; the byte-level resume after a drop is covered by the e2e fault proxy.
    @Test func droppedConnectionIsRetried() async throws {
        let (client, store, ref, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        nonisolated(unsafe) var cuts = 0
        BlobProtocol.handler = { [blob] req in
            if req.url!.path != "/v2/", cuts == 0 { cuts += 1; return (200, [:], Data(), true) }
            return (200, [:], blob, false)
        }
        try await client.fetchBlob(ref, digest: digest, expectedSize: Int64(blob.count), into: store)
        #expect(cuts == 1)
        #expect(try store.read(digest) == blob)
    }

    @Test func busyPartialIsNotSharedAndSweepSkipsIt() throws {
        let (_, store, _, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.openPartial(digest)
        try first.append(Data(repeating: 1, count: 10))
        let second = try store.openPartial(digest)
        #expect(first.isShared && !second.isShared)
        #expect(second.size == 0)
        #expect(store.sweepPartials() == 0)                          // locked, so left alone
        second.close(); first.close()
        #expect(store.sweepPartials() == 10)
    }

    @Test func oldPartialsAreSwept() throws {
        let (_, store, _, root) = try rig(); defer { try? FileManager.default.removeItem(at: root) }
        try plant(store, Data(repeating: 1, count: 5))
        #expect(store.sweepPartials(olderThan: 3600) == 0)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: store.partialURL(digest).path)
        #expect(store.sweepPartials(olderThan: 3600) == 5)
    }

    @Test func discardAfterPromoteNeverTruncatesTheBlob() throws {
        let (_, store, _, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = try store.openPartial(digest)
        try partial.append(blob)
        try partial.promote(into: store, as: digest)
        partial.discard()   // a late puller that lost the race takes this path
        #expect(store.size(digest) == Int64(blob.count))
        #expect(try Digest.sha256(file: store.url(digest)) == digest)
    }
}
