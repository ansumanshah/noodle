import Foundation
import NoodleCore

enum ModelPromptStream {
    @MainActor
    static func send(_ prompt: String, to endpoint: LocalModelEndpoint,
                     onText: @MainActor (String) -> Void) async throws {
        try await send(messages: [.init(role: .user, content: prompt)], to: endpoint, onText: onText)
    }

    @MainActor
    static func send(messages: [LocalModelChat.Message], to endpoint: LocalModelEndpoint,
                     settings: ModelChatSettings = .init(), onText: @MainActor (String) -> Void,
                     onMetrics: @MainActor (ModelGenerationMetrics) -> Void = { _ in }) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: Double?
        var decoder = ModelPromptDecoder()
        func metrics() -> ModelGenerationMetrics {
            ModelGenerationMetrics(timeToFirstToken: firstToken,
                                   elapsed: seconds(start.duration(to: clock.now)), outputTokens: decoder.outputTokens,
                                   cachedTokens: decoder.cachedTokens, promptTokens: decoder.promptTokens)
        }
        defer { onMetrics(metrics()) }
        let session = URLSession(configuration: sessionConfiguration())
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request(messages: messages, to: endpoint, settings: settings),
                                                           delegate: ModelPromptRedirectPolicy())
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if (response as? HTTPURLResponse)?.statusCode == 400 {
                    var body: [UInt8] = []
                    for try await byte in bytes { body.append(byte); if body.count >= 4096 { break } }
                    if ModelMemoryRefusal.matches(status: 400, body: String(decoding: body, as: UTF8.self)) {
                        throw ModelMemoryRefusal()
                    }
                    throw ModelPromptError("The conversation is too long for the model. Start a new chat.")
                }
                throw ModelPromptError("The model could not answer. Check the runner and try again.")
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                if let text = try decoder.consume(byte), !text.isEmpty {
                    let isFirstToken = firstToken == nil
                    if isFirstToken { firstToken = seconds(start.duration(to: clock.now)) }
                    onText(text)
                    if isFirstToken { onMetrics(metrics()) }
                }
                if decoder.isDone {
                    if decoder.finishReason == "length" { onText(Self.lengthNotice) }
                    return
                }
            }
            try Task.checkCancellation()
            try decoder.finish()
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        // No 90 s whole-transfer cap: long replies stream for minutes. The request's 90 s idle timeout still applies.
        configuration.timeoutIntervalForResource = 3_600
        return configuration
    }

    static let lengthNotice = "\n\n(Reply stopped at the length limit.)"

    static func request(_ prompt: String, to endpoint: LocalModelEndpoint) throws -> URLRequest {
        try request(messages: [.init(role: .user, content: prompt)], to: endpoint)
    }

    /// Only settings the user changed are sent; everything else keeps the model and server defaults.
    /// Context length is applied by the app when it trims history, because OpenAI-compatible servers take no such field.
    static func request(messages: [LocalModelChat.Message], to endpoint: LocalModelEndpoint,
                        settings: ModelChatSettings = .init()) throws -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        let body = try LocalModelChat.body(model: endpoint.model, messages: messages, maxTokens: settings.clamped.maxTokens)
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ModelPromptError("The test request could not be prepared.")
        }
        if let temperature = settings.clamped.temperature { object["temperature"] = temperature }
        object["stream"] = true
        // Reasoning models spend most of a short answer thinking; off unless the user asks for it.
        object["enable_thinking"] = settings.thinking ?? false
        object["stream_options"] = ["include_usage": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return request
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Buffers incomplete SSE lines, never token text. A delta is returned as soon as its event arrives.
struct ModelPromptDecoder {
    private(set) var isDone = false
    private(set) var outputTokens: Int?
    private(set) var cachedTokens: Int?
    private(set) var promptTokens: Int?
    private(set) var finishReason: String?
    private var line: [UInt8] = []
    private var data: [String] = []
    private var eventName = ""
    private var afterCR = false
    private var eventBytes = 0

    mutating func consume(_ byte: UInt8) throws -> String? {
        guard !isDone else { return nil }
        if byte == 10, afterCR { afterCR = false; return nil }
        afterCR = byte == 13
        if byte == 10 || byte == 13 { return try finishLine() }
        eventBytes += 1
        guard eventBytes <= 1_048_576 else { throw ModelPromptError("The model returned an oversized response event.") }
        line.append(byte)
        return nil
    }

    mutating func finish() throws {
        if !line.isEmpty { _ = try finishLine() }
        if !data.isEmpty { _ = try finishEvent() }
        guard isDone else { throw ModelPromptError("The response ended early. Try the prompt again.") }
    }

    private mutating func finishLine() throws -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return try finishEvent() }
        guard let value = String(bytes: line, encoding: .utf8) else {
            throw ModelPromptError("The model returned an unreadable response.")
        }
        if value.hasPrefix("data:") {
            var payload = value.dropFirst(5)
            if payload.first == " " { payload = payload.dropFirst() }
            data.append(String(payload))
        } else if value.hasPrefix("event:") {
            eventName = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private mutating func finishEvent() throws -> String? {
        defer { data.removeAll(keepingCapacity: true); eventName = ""; eventBytes = 0 }
        guard !data.isEmpty else { return nil }
        let payload = data.joined(separator: "\n")
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { isDone = true; return nil }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else {
            throw ModelPromptError("The model returned an unreadable response event.")
        }
        if chunk.error != nil || eventName == "error" {
            let message = chunk.error?.message ?? chunk.message ?? "The model could not finish the response."
            // Out of memory mid-reply: say so plainly, but never retry (the reply already started).
            if ModelMemoryRefusal.matchesMidStream(message) { throw ModelMemoryRefusal(transient: false) }
            throw ModelPromptError(message)
        }
        if let tokens = chunk.usage?.completion_tokens, tokens >= 0 { outputTokens = tokens }
        if let tokens = chunk.usage?.prompt_tokens, tokens >= 0 { promptTokens = tokens }
        if let cached = chunk.usage?.prompt_tokens_details?.cached_tokens, cached >= 0 { cachedTokens = cached }
        let choice = chunk.choices?.first(where: { ($0.index ?? 0) == 0 })
        if let reason = choice?.finish_reason { finishReason = reason }
        return choice?.delta?.content
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let index: Int?
            let delta: Delta?
            let finish_reason: String?
        }
        struct Failure: Decodable { let message: String }
        struct Usage: Decodable {
            struct Details: Decodable { let cached_tokens: Int? }
            let completion_tokens: Int?
            let prompt_tokens: Int?
            let prompt_tokens_details: Details?
        }
        let choices: [Choice]?
        let error: Failure?
        let message: String?
        let usage: Usage?
    }
}

struct ModelPromptError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ModelPromptRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
