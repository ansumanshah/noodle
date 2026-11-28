import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@Suite struct ModelGenerationMetricsTests {
    @Test func usageAndFinishReasonAreReadFromTheRunner() throws {
        var decoder = ModelPromptDecoder()
        let events = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: {\"choices\":[],\"usage\":{\"completion_tokens\":7}}\n\ndata: [DONE]\n\n"
        for byte in events.utf8 { _ = try decoder.consume(byte) }
        try decoder.finish()
        #expect(decoder.outputTokens == 7)
        #expect(decoder.finishReason == "stop")
        let metrics = ModelGenerationMetrics(timeToFirstToken: 0.2, elapsed: 2, outputTokens: decoder.outputTokens)
        #expect(metrics.timeToFirstToken == 0.2)
        #expect(metrics.tokensPerSecond == 3.5)
    }

    @Test func lengthFinishReasonIsDetectable() throws {
        var decoder = ModelPromptDecoder()
        for byte in "data: {\"choices\":[{\"delta\":{\"content\":\"cut\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n".utf8 {
            _ = try decoder.consume(byte)
        }
        try decoder.finish()
        #expect(decoder.finishReason == "length")
        #expect(ModelPromptStream.lengthNotice.contains("length limit"))
    }

    @Test func absentOrInvalidTokenUsageNeverBecomesAnEstimate() throws {
        var decoder = ModelPromptDecoder()
        for byte in "data: {\"choices\":[{\"delta\":{\"content\":\"A long answer is not a token count.\"}}]}\n\ndata: [DONE]\n\n".utf8 {
            _ = try decoder.consume(byte)
        }
        try decoder.finish()
        #expect(decoder.outputTokens == nil)
        #expect(ModelGenerationMetrics(elapsed: 1).tokensPerSecond == nil)
        #expect(ModelGenerationMetrics(elapsed: 0, outputTokens: 5).tokensPerSecond == nil)
        #expect(ModelGenerationMetrics(elapsed: 1, outputTokens: -1).outputTokens == nil)
        #expect(ModelGenerationMetrics(timeToFirstToken: .nan, elapsed: .infinity).timeToFirstToken == nil)
    }

    @Test func requestIncludesAllMessagesAndAsksForStreamUsage() throws {
        let endpoint = LocalModelEndpoint(model: "local", baseURL: URL(string: "http://127.0.0.1:11345/v1")!, apiKey: "fixture-key")
        let request = try ModelPromptStream.request(messages: [
            .init(role: .user, content: "First question"), .init(role: .assistant, content: "First answer"),
            .init(role: .user, content: "Follow-up"),
        ], to: endpoint)
        let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect((object["messages"] as? [[String: String]])?.map { $0["role"] } == ["user", "assistant", "user"])
        #expect((object["stream_options"] as? [String: Bool])?["include_usage"] == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    }

    /// At 15-25 tok/s a long reply streams for minutes; only the idle timeout may end it.
    @Test func longRepliesAreNotCutByAWholeTransferCap() throws {
        let endpoint = LocalModelEndpoint(model: "local", baseURL: URL(string: "http://127.0.0.1:11345/v1")!, apiKey: "k")
        #expect(ModelPromptStream.sessionConfiguration().timeoutIntervalForResource >= 3_600)
        #expect(try ModelPromptStream.request("hi", to: endpoint).timeoutInterval == 90)
    }
}
