import Testing
@testable import NoodleCore

@Suite struct ModelMemoryFitTests {
    private let gib: UInt64 = 1 << 30

    @Test func classifiesAgainstTotalMemory() {
        // 16 GiB Mac: reserve 2 GiB, usable 14. Good up to need 7 GiB, tight up to need 12 GiB.
        func fit(_ bytes: UInt64) -> ModelMemoryFit { ModelMemoryFit(modelBytes: bytes, totalMemory: 16 * gib) }
        #expect(fit(1_600_000_000) == .good)
        #expect(fit(4 * gib) == .good)      // needs 5.5 GiB
        #expect(fit(7 * gib) == .tight)     // needs 9.25 GiB
        #expect(fit(12 * gib) == .tooBig)   // needs 15.5 GiB
    }

    @Test func reserveIsClamped() {
        // 128 GiB: reserve capped at 8, so usable is 120 and good extends to need 60 GiB.
        #expect(ModelMemoryFit(modelBytes: 40 * gib, totalMemory: 128 * gib) == .good)
        #expect(ModelMemoryFit(modelBytes: 90 * gib, totalMemory: 128 * gib) == .tight)
    }

    @Test func tinyMemoryNeverUnderflows() {
        #expect(ModelMemoryFit(modelBytes: 1, totalMemory: gib) == .tooBig)
        #expect(ModelMemoryFit(modelBytes: 0, totalMemory: 0) == .tooBig)
        #expect(ModelMemoryFit(modelBytes: 1, totalMemory: 3 * gib) == .tooBig)
    }
}
