import Foundation
import Testing
@testable import NoodleApp

@Suite struct VMStatusTests {
    @Test func cpuIsAggregatePercentAndDiscardsCounterResets() {
        func sample(_ busy: UInt64, _ total: UInt64) -> VMReadiness.Usage {
            .init(cpus: 2, memoryMiB: 1024, memoryUsed: 128 << 20, cpuBusy: busy, cpuTotal: total)
        }
        #expect(sample(65, 200).percent(since: sample(40, 100)) == 25)
        #expect(sample(65, 100).percent(since: sample(40, 100)) == nil)
        #expect(sample(20, 200).percent(since: sample(40, 100)) == nil)
    }

    @Test func readinessLabelsTreatIdleAndUnknownAsNormal() throws {
        func label(_ state: String, _ running: Bool, _ ready: Bool) throws -> String? {
            let data = Data("{\"state\":\"\(state)\",\"vmRunning\":\(running),\"guestAgentReady\":\(ready)}".utf8)
            return try JSONDecoder().decode(VMReadiness.self, from: data).label
        }
        #expect(try label("stopped", false, false) == nil)
        #expect(try label("future", false, false) == nil)
        #expect(try label("starting", false, false) == "Starting VM…")
        #expect(try label("starting", true, false) == "Connecting to Linux…")
        #expect(try label("running", true, true) == nil)
        #expect(try label("stopping", true, false) == "Stopping VM…")
    }
}
