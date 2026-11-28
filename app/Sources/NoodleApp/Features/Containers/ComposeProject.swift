import Foundation

/// Compose records service dependencies as comma-separated name:condition:restart labels.
/// Operate on the project's existing containers without needing its original YAML on disk.
enum ComposeProject {
    enum OrderingError: LocalizedError {
        case cycle

        var errorDescription: String? { "The Compose project has a dependency cycle. No containers were changed." }
    }

    static func startOrder(_ containers: [ContainerSummary]) throws -> [ContainerSummary] {
        var remaining = containers.sorted {
            let serviceOrder = ($0.service ?? $0.name).localizedStandardCompare($1.service ?? $1.name)
            if serviceOrder != .orderedSame { return serviceOrder == .orderedAscending }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
        var ordered: [ContainerSummary] = []
        while !remaining.isEmpty {
            let services = Set(remaining.compactMap(\.service))
            guard let index = remaining.firstIndex(where: { container in
                let dependencies = (container.labels["com.docker.compose.depends_on"] ?? "")
                    .split(separator: ",")
                    .map { String($0.prefix { $0 != ":" }).trimmingCharacters(in: .whitespaces) }
                return services.isDisjoint(with: dependencies)
            }) else { throw OrderingError.cycle }
            ordered.append(remaining.remove(at: index))
        }
        return ordered
    }
}
