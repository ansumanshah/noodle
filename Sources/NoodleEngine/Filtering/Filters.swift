import Foundation
import NoodleCore
import NoodleImages

/// Filters in Docker's `filters` query parameter: `{"name":["web"],"label":["a=b"]}`.
public struct Filters: Sendable, Equatable {
    public var values: [String: [String]]
    public init(_ v: [String: [String]] = [:]) { values = v }

    /// Parse the JSON form (`{"status":["running"]}`) and the legacy `{"status":{"running":true}}` form.
    public static func parse(_ json: String?) -> Filters {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Filters() }
        var out: [String: [String]] = [:]
        for (k, v) in obj {
            if let arr = v as? [String] { out[k] = arr }
            else if let map = v as? [String: Any] { out[k] = map.compactMap { ($0.value as? Bool) == true ? $0.key : nil } }
        }
        return Filters(out)
    }

    public subscript(_ key: String) -> [String] { values[key] ?? [] }
    public func has(_ key: String) -> Bool { !(values[key] ?? []).isEmpty }
    public func bool(_ key: String) -> Bool? {
        guard let v = values[key]?.first else { return nil }
        return v == "true" || v == "1"
    }
    /// The first `label`/`label!` term with an empty key, which Docker answers with 400.
    public func firstInvalidLabel() -> String? {
        (self["label"] + self["label!"]).first { LabelFilter($0) == nil }
    }

    /// An unparsable term matches nothing, so an unvalidated caller cannot crash or widen a result.
    public func matchLabels(_ labels: [String: String]) -> Bool {
        for l in self["label"] {
            guard let f = LabelFilter(l), f.matches(labels) else { return false }
        }
        for l in self["label!"] {
            guard let f = LabelFilter(l), !f.matches(labels) else { return false }
        }
        return true
    }
}
