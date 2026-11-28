import Foundation

/// What `noodle import` does when the target already has an item with the same name.
public enum ImportConflictPolicy: String, Sendable, CaseIterable {
    case skip, overwrite, rename
}

public enum ImportDecision: Equatable, Sendable {
    case create(String)     // free to use this name
    case replace(String)    // remove the existing item, then create under this name
    case skip
}

public enum ImportNaming {
    /// Resolve a name against what the target already has.
    public static func decide(_ name: String, exists: (String) -> Bool, policy: ImportConflictPolicy) -> ImportDecision {
        guard exists(name) else { return .create(name) }
        switch policy {
        case .skip: return .skip
        case .overwrite: return .replace(name)
        case .rename:
            var candidate = name + "-imported"
            var n = 2
            while exists(candidate) { candidate = "\(name)-imported-\(n)"; n += 1 }
            return .create(candidate)
        }
    }

    /// Unix socket path for a Docker endpoint such as `unix:///var/run/docker.sock`.
    /// Remote transports are refused with advice, because the importer streams over a local socket only.
    public static func socketPath(host: String) throws -> String {
        if host.hasPrefix("unix://") { return String(host.dropFirst("unix://".count)) }
        if host.hasPrefix("/") { return host }
        throw Malformed(description: "unsupported endpoint \(host). Forward it to a local unix socket first (for example ssh -L).")
    }

    public struct Malformed: Error, CustomStringConvertible { public let description: String }

    /// Docker context endpoint host from a context's meta.json, nil when the file is not a docker context.
    public static func contextHost(metaJSON: Data) -> (name: String, host: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: metaJSON) as? [String: Any],
              let name = root["Name"] as? String,
              let endpoints = root["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String else { return nil }
        return (name, host)
    }
}
