import Foundation

/// Ollama-style durations. A nil interval disables idle eviction.
public struct LocalModelKeepAlive: Codable, Equatable, Sendable {
    public static let `default` = Self(seconds: 300)
    public let seconds: TimeInterval?

    private init(seconds: TimeInterval?) { self.seconds = seconds }

    public init(_ text: String) throws {
        let invalid = CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey:
            "invalid keep-alive duration '\(text)'. Use 5m, 1h, 0, or a negative duration to keep the model loaded."])
        guard !text.isEmpty else { throw invalid }
        var value = text[...]
        let negative = value.first == "-"
        if negative || value.first == "+" { value = value.dropFirst() }
        guard !value.isEmpty else { throw invalid }
        var total: Double = 0
        if value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(value) {
            total = number
        } else {
            let units: [(String, Double)] = [("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("μs", 1e-6),
                                              ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600)]
            while !value.isEmpty {
                let digits = value.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }
                guard digits.contains(where: { $0 != "." }), digits.filter({ $0 == "." }).count <= 1,
                      let number = Double(digits), number.isFinite else { throw invalid }
                value = value.dropFirst(digits.count)
                guard let (unit, scale) = units.first(where: { value.hasPrefix($0.0) }) else { throw invalid }
                total += number * scale
                value = value.dropFirst(unit.count)
            }
        }
        // Go durations use signed 64-bit nanoseconds.
        guard total.isFinite, total <= Double(Int64.max) / 1e9 else { throw invalid }
        seconds = negative && total > 0 ? nil : total
    }

    /// The shared engine accepts unsigned 32-bit seconds; nil disables eviction.
    public func idleEvictSeconds() throws -> UInt32? {
        guard let seconds else { return nil }
        let rounded = max(1, seconds.rounded(.up))
        guard let value = UInt32(exactly: rounded) else {
            throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey:
                "keep-alive exceeds the maximum of \(UInt32.max) seconds"])
        }
        return value
    }
}
