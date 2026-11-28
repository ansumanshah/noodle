import Foundation

/// Durations use a monotonic clock. Token counts are supplied by the runner, never inferred from text.
struct ModelGenerationMetrics: Equatable, Sendable {
    let timeToFirstToken: Double?
    let elapsed: Double
    let outputTokens: Int?
    let cachedTokens: Int?
    let promptTokens: Int?

    /// Average output throughput across the whole request, including the initial wait.
    var tokensPerSecond: Double? {
        guard let outputTokens, outputTokens >= 0, elapsed > 0 else { return nil }
        return Double(outputTokens) / elapsed
    }

    /// Words per second while writing the reply, after the first word arrived.
    // shortcut: about 0.75 words per token; count the reply's words if exact figures matter.
    var wordsPerSecond: Double? {
        guard let outputTokens, outputTokens > 0 else { return nil }
        let writing = elapsed - (timeToFirstToken ?? 0)
        return writing > 0 ? Double(outputTokens) * 0.75 / writing : nil
    }

    init(timeToFirstToken: Double? = nil, elapsed: Double, outputTokens: Int? = nil, cachedTokens: Int? = nil,
         promptTokens: Int? = nil) {
        self.timeToFirstToken = timeToFirstToken.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.outputTokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.cachedTokens = cachedTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.promptTokens = promptTokens.flatMap { $0 >= 0 ? $0 : nil }
    }
}

extension ModelGenerationMetrics {
    /// "12 words/s · 0.3 s to first word · from cache", whichever parts are known.
    var speedLine: String? {
        var parts: [String] = []
        if let rate = wordsPerSecond { parts.append(String(localized: "\(rate.formatted(.number.precision(.fractionLength(0)))) words/s")) }
        if let first = timeToFirstToken {
            parts.append(String(localized: "\(first.formatted(.number.precision(.fractionLength(1)))) s to first word"))
        }
        // A few shared tokens are not worth a mention; say it only when most of the prompt was reused.
        if let cachedTokens, let promptTokens, cachedTokens > 0, cachedTokens * 2 >= promptTokens { parts.append(String(localized: "from cache")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
