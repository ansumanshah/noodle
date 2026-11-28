/// Validates the component-log argument shape without I/O.
public enum LogsRoute: Equatable, Sendable {
    case component
    case invalid
}

public enum LogsRouting {
    static let valueOptions: Set<String> = ["-n", "--tail", "--grep"]
    static let flagOptions: Set<String> = ["-f", "--follow", "--raw"]

    public static func route(_ args: [String]) -> LogsRoute {
        var i = 0
        var componentSeen = false
        while i < args.count {
            let a = args[i]
            if valueOptions.contains(a) {
                guard i + 1 < args.count else { return .invalid }
                i += 2
                continue
            }
            if flagOptions.contains(a) { i += 1; continue }
            guard !componentSeen, LogComponent(rawValue: a) != nil else { return .invalid }
            componentSeen = true
            i += 1
        }
        return .component
    }
}
