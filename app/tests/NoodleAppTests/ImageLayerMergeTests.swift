import Foundation
import Testing
@testable import NoodleApp

@Suite struct ImageLayerMergeTests {
    private func history(_ steps: [(String, Int)]) throws -> [ImageHistory] {
        let rows = steps.map { ["CreatedBy": $0.0, "Size": $0.1, "Created": 100] as [String: Any] }
        return try JSONDecoder().decode([ImageHistory].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    private func catalog(_ layers: [(String, String, Int)]) throws -> [CatalogImageLayer] {
        let rows = layers.map { ["digest": $0.0, "instruction": $0.1, "size": $0.2] as [String: Any] }
        return try JSONDecoder().decode([CatalogImageLayer].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    /// Docker lists the newest step first. Rows come out base first, and only steps that wrote a layer carry a digest.
    @Test func pairsStoredLayersWithTheirSteps() throws {
        let rows = ImageLayerRow.merge(history: try history([("CMD [\"sh\"]", 0), ("RUN make", 50), ("ENV A=1", 0), ("ADD rootfs /", 900)]),
                                       catalog: try catalog([("sha256:aa", "ADD rootfs /", 1000), ("sha256:bb", "RUN make", 60)]))
        #expect(rows.map(\.instruction) == ["ADD rootfs /", "ENV A=1", "RUN make", "CMD [\"sh\"]"])
        #expect(rows.map(\.digest) == ["sha256:aa", nil, "sha256:bb", nil])
        #expect(rows.map(\.size) == [1000, 0, 60, 0])
        #expect(rows.map(\.id) == [1, 2, 3, 4])
    }

    /// A digest on the wrong step is worse than a shorter list.
    @Test func showsStoredLayersAloneWhenTheStepsDoNotPairUp() throws {
        let rows = ImageLayerRow.merge(history: try history([("RUN other", 5), ("ADD rootfs /", 900)]),
                                       catalog: try catalog([("sha256:aa", "ADD rootfs /", 1000), ("sha256:bb", "RUN make", 60)]))
        #expect(rows.map(\.digest) == ["sha256:aa", "sha256:bb"])
        #expect(rows.allSatisfy { $0.created == nil })
    }

    @Test func fallsBackToEitherSource() throws {
        let steps = try history([("RUN make", 50), ("ADD rootfs /", 900)])
        #expect(ImageLayerRow.merge(history: steps, catalog: nil).map(\.instruction) == ["ADD rootfs /", "RUN make"])
        #expect(ImageLayerRow.merge(history: [], catalog: try catalog([("sha256:aa", "ADD rootfs /", 1)])).count == 1)
        #expect(ImageLayerRow.merge(history: [], catalog: nil).isEmpty)
    }

    @Test func metadataStepWithTheSameInstructionCannotTakeTheDigest() throws {
        let rows = ImageLayerRow.merge(history: try history([("RUN make", 50), ("RUN make", 0)]),
                                       catalog: try catalog([("sha256:bb", "RUN make", 60)]))
        #expect(rows.map(\.digest) == [nil, "sha256:bb"])
    }

    @Test func commandDropsTheShellWrapper() {
        func row(_ text: String) -> String { ImageLayerRow(id: 1, instruction: text, size: 0, digest: nil, created: nil).command }
        #expect(row("/bin/sh -c #(nop)  CMD [\"sh\"]") == "CMD [\"sh\"]")
        #expect(row("/bin/sh -c apk add curl") == "RUN apk add curl")
        #expect(row("RUN /bin/sh -c make # buildkit") == "RUN /bin/sh -c make # buildkit")
        #expect(row("") == "Image layer")
    }

    @Test func severitySortPutsTheWorstFirst() async throws {
        let json = #"{"matches":[{"artifact":{"name":"a"},"vulnerability":{"id":"B","severity":"Low"}},{"artifact":{"name":"b"},"vulnerability":{"id":"A","severity":"critical"}},{"artifact":{"name":"c"},"vulnerability":{"id":"C","severity":"Odd"}}]}"#
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(json.utf8))
        #expect(report.sorted.map(\.vulnerability.id) == ["A", "B", "C"])
    }

    @MainActor @Test func scanHistoryFollowsImageIDWhenATagMoves() async throws {
        let original = try await SecurityStore.history(for: "sha256:8192a3b4c5d6", demo: true)
        #expect(original.first?.image == "alpine:3.22")
        #expect(original.first?.result.matches.count == 2)
        let replacement = try await SecurityStore.history(for: "sha256:other", demo: true)
        #expect(replacement.isEmpty)
    }
}
