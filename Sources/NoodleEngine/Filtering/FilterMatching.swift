import Foundation

/// Docker's list-filter semantics shared by containers, networks and volumes.
extension Filters {
    /// Docker matches `name` filters as unanchored regular expressions, so `^web$` means exactly web.
    /// A pattern that is not a valid expression matches nothing.
    public func regexMatches(_ key: String, _ candidate: String) -> Bool {
        let patterns = self[key]
        if patterns.isEmpty { return true }
        return patterns.contains { p in
            guard let re = try? NSRegularExpression(pattern: p) else { return false }
            return re.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        }
    }

    /// Container names carry a leading slash in Docker; a pattern may be written with or without it.
    public func nameMatches(_ name: String) -> Bool {
        regexMatches("name", name) || regexMatches("name", "/" + name)
    }

    /// The first filter key outside `allowed`, which Docker answers with 400 "Invalid filter".
    public func firstUnknownKey(allowed: Set<String>) -> String? {
        values.keys.sorted().first { !allowed.contains($0) && !(allowed.contains($0.hasSuffix("!") ? String($0.dropLast()) : $0)) }
    }
}

public enum FilterKeys {
    public static let containers: Set<String> = ["id", "name", "label", "exited", "status", "ancestor", "before", "since",
                                                 "volume", "network", "publish", "expose", "health", "isolation", "is-task"]
    public static let containerStatuses: Set<String> = ["created", "restarting", "running", "removing", "paused", "exited", "dead"]
    public static let healthValues: Set<String> = ["starting", "healthy", "unhealthy", "none"]
    public static let networks: Set<String> = ["driver", "id", "label", "name", "scope", "type", "dangling"]
    public static let volumes: Set<String> = ["dangling", "driver", "label", "name"]
    public static let images: Set<String> = ["before", "dangling", "label", "reference", "since", "until"]
}
