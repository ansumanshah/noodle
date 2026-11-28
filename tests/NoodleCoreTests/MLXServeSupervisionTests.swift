import Foundation
import Testing
@testable import NoodleCore

@Suite(.tags(.slow)) struct MLXServeSupervisionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func backoffDoublesToTheCapThenGivesUpOnTheFifthCrash() {
        var policy = MLXServeCrashPolicy()
        let decisions = (0..<5).map { policy.recordCrash(at: start.addingTimeInterval(Double($0))) }
        #expect(decisions == [.restart(after: 1), .restart(after: 2), .restart(after: 4), .restart(after: 8), .giveUp])
    }

    @Test func crashesOutsideTheWindowAreForgotten() {
        var policy = MLXServeCrashPolicy()
        for second in 0..<4 { _ = policy.recordCrash(at: start.addingTimeInterval(Double(second))) }
        #expect(policy.recordCrash(at: start.addingTimeInterval(700)) == .restart(after: 1))
    }

    @Test func memoryRefusalIsDetectedAndKeepsTheDetail() {
        let body = #"{"error":{"message":"Prompt (68 tokens) requires ~654MB GPU memory but only ~89MB is available"}}"#
        #expect(LocalModelMemoryRefusal.matches(body))
        let message = LocalModelMemoryRefusal.userMessage(for: body)
        #expect(message?.hasPrefix(LocalModelMemoryRefusal.message + "\n") == true)
        #expect(message?.contains("654MB GPU memory") == true)
        #expect(!LocalModelMemoryRefusal.matches(#"{"error":{"message":"bad request"}}"#))
        #expect(LocalModelMemoryRefusal.userMessage(for: "nope") == nil)
        #expect(!LocalModelMemoryRefusal.matches("Prompt requires ~9000MB GPU memory, more than is available even after freeing the prefix cache"))
    }

    @Test func statusDecodesWithoutCrashFields() throws {
        let status = try JSONDecoder().decode(LocalModelStatus.self, from: Data(#"{"phase":"ready"}"#.utf8))
        #expect(status.restarts == nil && status.lastCrash == nil)
    }
}
