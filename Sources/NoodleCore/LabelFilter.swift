import Foundation

/// One `label` filter term: `key` or `key=value` (an empty value is allowed, an empty key is not).
public struct LabelFilter: Sendable, Equatable {
    public let key: String
    public let value: String?

    public init?(_ term: String) {
        let parts = term.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let k = parts.first, !k.isEmpty else { return nil }
        key = String(k)
        value = parts.count == 2 ? String(parts[1]) : nil
    }

    public func matches(_ labels: [String: String]) -> Bool {
        guard let v = labels[key] else { return false }
        return value == nil || v == value
    }
}
