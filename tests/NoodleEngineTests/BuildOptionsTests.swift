import Foundation
import Testing
@testable import NoodleEngine

@Test func buildOptionsConfineContextAndKeepArgumentsLiteral() throws {
    for path in ["", "/Dockerfile", "../outside", "a/../Dockerfile", "Dockerfile\u{0}other"] {
        #expect(throws: EngineError.self) { try BuildOptions(dockerfile: path) }
    }
    #expect(throws: EngineError.self) { try BuildOptions(tags: ["repo@sha256:" + String(repeating: "0", count: 64)]) }
    #expect(throws: EngineError.self) { try BuildOptions(network: "host") }
    let options = try BuildOptions(dockerfile: "docker/Dev", args: ["MESSAGE": "x=1 $(id)"], tags: ["local/image"],
                                   target: "final", network: "none")
    #expect(options.options == ["build-arg:MESSAGE=x=1 $(id)", "target=final", "force-network-mode=none"])
    #expect(options.tags == ["local/image:latest"])
}

@Test func buildProviderSurvivesPruneAndForcedRemovalUntilCompletion() async throws {
    let paths = tempPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let engine = Engine(paths: paths)
    let image = try await makeImage(engine)
    let store = engine.imageStore
    try await store.withBuildProvider(image.id) { provider in
        await #expect(throws: ImageError.self) { _ = try await store.remove(provider.id, force: true) }
        let during = try await store.prune(danglingOnly: false, inUse: [])
        #expect(during.deleted.isEmpty)
        #expect(await store.get(id: provider.id) != nil)
    }
    let after = try await store.prune(danglingOnly: false, inUse: [])
    #expect(after.deleted == [image.id])
}

@Test func buildContextLimitsAndCancellation() async throws {
    let work = tempPaths().root
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let tar = work.appendingPathComponent("upload")
    try Data(repeating: 0, count: 150_000).write(to: tar)
    let gz = work.appendingPathComponent("upload.gz")
    _ = try Gzip.compress(tar, to: gz)
    let plain = work.appendingPathComponent("output")
    #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(gz, to: plain, maximumSize: 65_536) }
    #expect(try plain.resourceValues(forKeys: [.fileSizeKey]).fileSize == 65_536)
    let decoded = try Gzip.decompress(gz, to: plain, maximumSize: 150_000)
    #expect(decoded.size == 150_000)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try Gzip.decompress(gz, to: plain)
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    let file = try FileHandle(forWritingTo: tar)
    try file.truncate(atOffset: UInt64(BuildOptions.maximumContextBytes) + 1)
    try file.close()
    await #expect(throws: EngineError.self) { _ = try await Engine.prepareBuildContext(tar, in: work) }
}
