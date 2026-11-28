import Foundation
import Testing
@testable import NoodleImages
@testable import NoodleCore

@Suite struct ImageStorageTests {
    @Test func blobStoreVerifiesDigests() throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlobStore(paths: NoodlePaths(root: dir))
        let digest = try store.put(Data("payload".utf8))
        #expect(digest == Digest.sha256(Data("payload".utf8)))
        #expect(store.has(digest))
        #expect(store.size(digest) == 7)
        #expect(try store.read(digest) == Data("payload".utf8))
        let bad = store.tempURL()
        try Data("other".utf8).write(to: bad)
        #expect(throws: ImageError.self) { try store.adopt(file: bad, expected: digest) }
        #expect(!FileManager.default.fileExists(atPath: bad.path))      // rejected download is deleted
        #expect(store.all().map(\.digest) == [digest])
        store.remove(digest)
        #expect(!store.has(digest))
    }

    @Test func tarRoundTripIncludingLongNames() throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.tar")
        let long = String(repeating: "d/", count: 80) + "file.txt"      // > 100 bytes forces a GNU long name entry
        let w = try TarWriter(url: url)
        try w.addFile("small.txt", data: Data("abc".utf8))
        try w.addDirectory("folder")
        try w.addFile(long, data: Data(repeating: 7, count: 1000))
        try w.finish()
        let r = try TarReader(url: url)
        let e1 = try #require(try r.next())
        #expect(e1.name == "small.txt"); #expect(e1.size == 3); #expect(e1.isFile)
        #expect(try r.readData(e1) == Data("abc".utf8))
        let e2 = try #require(try r.next())
        #expect(e2.isDirectory); #expect(e2.name == "folder/")
        let e3 = try #require(try r.next())
        #expect(e3.name == long); #expect(e3.size == 1000)
        let out = dir.appendingPathComponent("copy")
        try r.copy(e3, to: out)
        #expect(try Data(contentsOf: out) == Data(repeating: 7, count: 1000))
        #expect(try r.next() == nil)
    }

    @Test func gzipRoundTrip() throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("plain")
        var data = Data()
        for i in 0..<200_000 { data.append(UInt8(truncatingIfNeeded: i &* 31 &+ i >> 3)) }
        data.append(Data(repeating: 0, count: 300_000))
        try data.write(to: src)
        let gz = dir.appendingPathComponent("plain.gz")
        let res = try Gzip.compress(src, to: gz)
        #expect(res.inputSize == Int64(data.count))
        #expect(res.inputDigest == Digest.sha256(data))
        #expect(res.outputDigest == (try Digest.sha256(file: gz)))
        #expect(res.outputSize < res.inputSize)
        #expect(Gzip.isGzip(gz))
        let back = dir.appendingPathComponent("back")
        let d = try Gzip.decompress(gz, to: back)
        #expect(d.digest == res.inputDigest); #expect(d.size == Int64(data.count))
        #expect(try Data(contentsOf: back) == data)
        // interoperates with the system gzip
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-t", gz.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func gzipRefusesADestinationItCannotRecreate() throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("plain"), gz = dir.appendingPathComponent("plain.gz")
        try Data("new".utf8).write(to: src)
        _ = try Gzip.compress(src, to: gz)
        let locked = dir.appendingPathComponent("locked"), dest = locked.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 4096).write(to: dest)
        chmod(locked.path, 0o555); defer { chmod(locked.path, 0o755) }
        // Writing over the old file without truncating it would leave its stale tail behind.
        #expect(throws: POSIXError.self) { _ = try Gzip.decompress(gz, to: dest) }
        #expect(try Data(contentsOf: dest).count == 4096)
    }

    @Test func gzipConcatenatedMembersAndChecksum() throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        var members = Data(), whole = Data()
        for n in 1...2 {
            let src = dir.appendingPathComponent("p\(n)"), gz = dir.appendingPathComponent("p\(n).gz")
            let part = Data(repeating: UInt8(n), count: 100_000 * n)
            try part.write(to: src)
            _ = try Gzip.compress(src, to: gz)
            members.append(try Data(contentsOf: gz)); whole.append(part)
        }
        let joined = dir.appendingPathComponent("joined.gz"), back = dir.appendingPathComponent("back")
        try members.write(to: joined)
        #expect(try Gzip.decompress(joined, to: back).size == Int64(whole.count))
        #expect(try Data(contentsOf: back) == whole)

        var bad = members; bad[bad.count - 8] ^= 0xff  // CRC32 of the last member
        try bad.write(to: joined)
        #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(joined, to: back) }
        try (members + Data([0, 0, 0])).write(to: joined)  // trailing garbage
        #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(joined, to: back) }
    }

    @Test func loadRejectsInvalidRepoTag() async throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ImageStore(paths: NoodlePaths(root: dir))
        let layer = store.blobs.tempURL()
        let w = try TarWriter(url: layer); try w.addFile("x", data: Data("1".utf8)); try w.finish()
        let ld = try Digest.sha256(file: layer)
        let size = (try FileManager.default.attributesOfItem(atPath: layer.path)[.size] as? NSNumber)!.int64Value
        try store.blobs.install(layer, as: ld)
        var cfg = ImageConfig(); cfg.architecture = "arm64"; cfg.os = "linux"; cfg.created = ISO8601.string(Date())
        _ = try await store.register(config: cfg, layers: [LayerRef(digest: ld, diffID: ld, mediaType: MediaType.ociLayerTar, size: size)], tags: ["a/b:1"])
        let good = dir.appendingPathComponent("good.tar"), bad = dir.appendingPathComponent("bad.tar")
        try await store.save(["a/b:1"], to: good)
        // Copy the archive, swapping the manifest's RepoTags for one no reference parser accepts.
        let reader = try TarReader(url: good), writer = try TarWriter(url: bad)
        var n = 0
        while let e = try reader.next() {
            guard e.isFile else { continue }
            let part = dir.appendingPathComponent("part\(n)"); n += 1
            try reader.copy(e, to: part)
            var data = try Data(contentsOf: part)
            if e.name == "manifest.json" {
                var items = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                items[0]["RepoTags"] = ["UPPER::case:::tag"]
                data = try JSONSerialization.data(withJSONObject: items)
            }
            try writer.addFile(e.name, data: data)
        }
        try writer.finish()
        let other = ImageStore(paths: NoodlePaths(root: try scratchDir("img")))
        await #expect(throws: ImageError.self) { _ = try await other.load(from: bad) }
    }

    @Test func saveAndLoadKeepsDigests() async throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let paths = NoodlePaths(root: dir)
        let store = ImageStore(paths: paths)
        let layer = store.blobs.tempURL()
        let w = try TarWriter(url: layer); try w.addFile("x", data: Data("1".utf8)); try w.finish()
        let ld = try Digest.sha256(file: layer)
        let size = (try FileManager.default.attributesOfItem(atPath: layer.path)[.size] as? NSNumber)!.int64Value
        try store.blobs.install(layer, as: ld)
        var cfg = ImageConfig(); cfg.architecture = "arm64"; cfg.os = "linux"; cfg.created = ISO8601.string(Date())
        let img = try await store.register(config: cfg, layers: [LayerRef(digest: ld, diffID: ld, mediaType: MediaType.ociLayerTar, size: size)], tags: ["a/b:1", "a/b:latest"])
        let out = dir.appendingPathComponent("out.tar")
        try await store.save(["a/b:1"], to: out)

        let other = ImageStore(paths: NoodlePaths(root: try scratchDir("img")))
        let loaded = try await other.load(from: out)
        #expect(loaded.count == 1)
        #expect(loaded[0].id == img.id)
        #expect(Set(loaded[0].repoTags) == ["a/b:1", "a/b:latest"])
        #expect(loaded[0].layers.first?.digest == ld)
        // gzip-wrapped archives load as well
        let gz = dir.appendingPathComponent("out.tar.gz")
        _ = try Gzip.compress(out, to: gz)
        let third = ImageStore(paths: NoodlePaths(root: try scratchDir("img")))
        #expect(try await third.load(from: gz).first?.id == img.id)
    }

    @Test func tagMovesBetweenImages() async throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ImageStore(paths: NoodlePaths(root: dir))
        var c1 = ImageConfig(); c1.created = "2026-01-01T00:00:00Z"
        var c2 = ImageConfig(); c2.created = "2026-02-01T00:00:00Z"
        let l = LayerRef(digest: "sha256:" + String(repeating: "1", count: 64), diffID: "sha256:" + String(repeating: "1", count: 64), mediaType: MediaType.ociLayerTar, size: 1)
        let a = try await store.register(config: c1, layers: [l], tags: ["app:latest"])
        let b = try await store.register(config: c2, layers: [l], tags: ["app:latest"])
        #expect(a.id != b.id)
        let resolved = try await store.resolve("app")
        #expect(resolved.id == b.id)
        let aNow = try #require(await store.get(id: a.id))
        #expect(aNow.isDangling)
        let pruned = try await store.prune(danglingOnly: true, inUse: [])
        #expect(pruned.deleted == [a.id])
        await #expect(throws: ImageError.self) { try await store.resolve("does-not-exist") }
    }

    @Test func dockerConfigReadsInlineAuth() async throws {
        let dir = try scratchDir("img"); defer { try? FileManager.default.removeItem(at: dir) }
        let auth = Data("user:secret".utf8).base64EncodedString()
        try Data(#"{"auths":{"ghcr.io":{"auth":"\#(auth)"},"https://index.docker.io/v1/":{"auth":"\#(auth)"}},"credsStore":"nonexistent-helper"}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        let cfg = DockerConfig(configDir: dir, environment: [:])
        let c = await cfg.credential(forRegistry: "ghcr.io")
        #expect(c?.username == "user"); #expect(c?.password == "secret")
        #expect(await cfg.credential(forRegistry: "registry-1.docker.io")?.username == "user")
        #expect(await cfg.credential(forRegistry: "quay.io") == nil)    // missing helper is not fatal
    }
}
