import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    public func pruneContainers(filters: Filters = Filters()) async -> ContainerPruneResponse {
        var out = ContainerPruneResponse()
        let cutoff = filters["until"].first.flatMap { Self.parseUntil($0) }
        for c in containers.values where !c.isRunningLike && filters.matchLabels(c.config.Labels ?? [:]) {
            if let cutoff, c.created >= cutoff { continue }
            if (try? await removeContainer(c.id, force: false)) != nil { out.ContainersDeleted.append(c.id) }
        }
        return out
    }

    static func parseUntil(_ s: String) -> Date? {
        if let t = Double(s) { return Date(timeIntervalSince1970: t) }
        if let d = ISO8601.parse(s) { return d }
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600]
        if let u = s.last, let m = units[u], let n = Double(s.dropLast()) { return Date().addingTimeInterval(-n * m) }
        return nil
    }
}
