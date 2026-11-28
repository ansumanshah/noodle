import Foundation
import Testing
@testable import NoodleApp

/// 9dff9d0: scan data decodes off the main actor.
@Suite struct SecurityStoreDecodeTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func record(_ onMain: Bool) { lock.withLock { values.append(onMain) } }
        var all: [Bool] { lock.withLock { values } }
    }
    static let seen = Seen()

    /// Records the thread its decoder ran on.
    struct Probe: Decodable, Sendable {
        init(from decoder: Decoder) throws { SecurityStoreDecodeTests.seen.record(Thread.isMainThread) }
    }

    @MainActor @Test func decodeRunsOffTheMainActor() async throws {
        let before = Self.seen.all.count
        _ = try await SecurityStore.decode(Probe.self, from: Data("{}".utf8))
        let new = Self.seen.all.dropFirst(before)
        #expect(new.count == 1)
        #expect(new.allSatisfy { !$0 }, "the decoder ran on the main thread")
    }

    /// Other main-actor tests can hold the actor for the whole decode, so this checks results only.
    /// decodeRunsOffTheMainActor proves the isolation.
    @MainActor @Test func largeHistoryDecodesCorrectly() async throws {
        let match = #"{"artifact":{"name":"pkg","version":"1.0"},"vulnerability":{"id":"CVE-2026-0001","severity":"High","fix":{"versions":["1.1"]}}}"#
        let matches = Array(repeating: match, count: 400).joined(separator: ",")
        let entry = #"{"image":"alpine:3.22","imageID":"sha256:abc","created":"2026-11-07T00:00:00Z","scanner":"grype","version":"1","result":{"matches":[\#(matches)]}}"#
        let data = Data("[\(Array(repeating: entry, count: 300).joined(separator: ","))]".utf8)
        let history = try await SecurityStore.decode([ScanHistoryEntry].self, from: data)
        #expect(history.count == 300)
        #expect(history[0].result.count("high") == 400)
    }
}
