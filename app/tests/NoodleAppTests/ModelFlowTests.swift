import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@Suite struct ModelPromptDecoderTests {
    @Test func fragmentedEventsPreserveWhitespaceAndUnicode() throws {
        var decoder = ModelPromptDecoder()
        let first = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"  Héllo\\n\"}}]}\r\n\r\n"
        var text = ""
        // One-byte delivery also splits the UTF-8 character and both CRLF separators.
        for byte in first.utf8 {
            if let delta = try decoder.consume(byte) { text += delta }
        }
        #expect(text == "  Héllo\n")
        #expect(!decoder.isDone, "The first token must be available before the stream completes.")
        for byte in "data: {\"choices\":[{\"delta\":{\"content\":\" world \"}}]}\n\ndata: [DONE]\n\n".utf8 {
            if let delta = try decoder.consume(byte) { text += delta }
        }
        try decoder.finish()
        #expect(text == "  Héllo\n world ")
        #expect(decoder.isDone)
    }

    @Test func roleUsageCommentsAndMultilineDataAreHandled() throws {
        let events = """
        : keepalive

        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":
        data: [{"delta":{"content":"hello"}}]}

        data: {"choices":[],"usage":{"completion_tokens":1}}

        data: [DONE]


        """
        let result = try decode(events)
        #expect(result == ["hello"])
    }

    @Test func unfinishedStreamAndMalformedEventsFail() throws {
        #expect(throws: ModelPromptError.self) {
            try decode("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"stop\"}]}\n\n")
        }
        #expect(throws: ModelPromptError.self) { try decode("data: not-json\n\n") }
    }

    @Test func serverErrorEventsAreVisible() throws {
        do {
            _ = try decode("event: error\ndata: {\"error\":{\"message\":\"The model ran out of memory.\"}}\n\n")
            Issue.record("A server error must fail the response.")
        } catch let error as ModelPromptError {
            #expect(error.message == "The model ran out of memory.")
        }
    }

    @Test func requestEnablesStreamingWithoutChangingPromptOrCredentials() throws {
        let endpoint = LocalModelEndpoint(model: "local-model", baseURL: URL(string: "http://127.0.0.1:11345/v1")!,
                                          apiKey: "fixture-key")
        let request = try ModelPromptStream.request("  Hello\n", to: endpoint)
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "local-model")
        #expect((body["messages"] as? [[String: String]])?.first?["content"] == "  Hello\n")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.url?.path == "/v1/chat/completions")
    }

    private func decode(_ events: String) throws -> [String] {
        var decoder = ModelPromptDecoder()
        var deltas: [String] = []
        for byte in events.utf8 {
            if let delta = try decoder.consume(byte) { deltas.append(delta) }
        }
        try decoder.finish()
        return deltas
    }
}

@MainActor @Suite struct ModelFlowTests {
    @Test func cancellationStopsTheOwnedOperationAndKeepsPartialText() async {
        let response = ModelPromptResponse()
        let started = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); pending.continuation.finish() }
        let run = Task {
            await response.run { emit in
                emit("first ")
                started.continuation.yield(())
                for await _ in pending.stream {}
                emit("late token")
            }
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(response.text == "first ")
        #expect(response.state == .receiving)
        response.cancel()
        #expect(response.state == .cancelling)
        await run.value
        #expect(response.state == .cancelled)
        #expect(response.failure == nil)
        #expect(response.text == "first ")
        #expect(!response.canCancel)
        await response.run { emit in emit("next response") }
        #expect(response.state == .completed)
        #expect(response.text == "next response")
    }

    @Test func cancellingTheCallerWhileWaitingCancelsTheRequest() async {
        let response = ModelPromptResponse()
        let started = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); pending.continuation.finish() }
        let run = Task {
            await response.run { _ in
                started.continuation.yield(())
                for await _ in pending.stream {}
            }
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(response.state == .waiting)
        run.cancel()
        await run.value
        #expect(response.state == .cancelled)
        #expect(response.failure == nil)
        #expect(response.text.isEmpty)
    }

    @Test func emptyResponsesAndStreamFailuresDoNotLookCompleted() async {
        let response = ModelPromptResponse()
        await response.run { emit in emit(" \n") }
        #expect(response.state == .failed)
        #expect(response.failure?.contains("empty response") == true)
        await response.run { emit in
            emit("partial")
            throw ModelPromptError("The response ended early.")
        }
        #expect(response.state == .failed)
        #expect(response.text == "partial")
        #expect(response.failure == "The response ended early.")
    }

    @Test func receivingDemoIsDistinctFromCompletedResponse() {
        let receiving = ModelsPageStore(demo: true, demoState: .receiving)
        let completed = ModelsPageStore(demo: true, demoState: .running)
        #expect(receiving.response.state == .receiving)
        #expect(receiving.activity == .prompt)
        #expect(!receiving.reply.isEmpty)
        #expect(completed.response.state == .completed)
        #expect(completed.activity == nil)
    }
}
