import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: Dockerfile-style `changes` for commit/import

    static func runtimeConfig(from c: ContainerConfig) -> ImageConfig.RuntimeConfig {
        var r = ImageConfig.RuntimeConfig()
        r.user = c.User.isEmpty ? nil : c.User; r.env = c.Env; r.entrypoint = c.Entrypoint; r.cmd = c.Cmd
        r.workingDir = c.WorkingDir.isEmpty ? nil : c.WorkingDir; r.labels = c.Labels
        r.exposedPorts = c.ExposedPorts?.mapValues { _ in ImageConfig.EmptyObject() }
        r.volumes = c.Volumes?.mapValues { _ in ImageConfig.EmptyObject() }
        r.stopSignal = c.StopSignal; r.shell = c.Shell
        if let h = c.Healthcheck { var hh = ImageConfig.Health(); hh.test = h.Test; hh.interval = h.Interval; hh.timeout = h.Timeout; hh.startPeriod = h.StartPeriod; hh.startInterval = h.StartInterval; hh.retries = h.Retries; r.healthcheck = hh }
        return r
    }

    static func applyChanges(_ changes: [String], to cfg: inout ContainerConfig) {
        func list(_ rest: String) -> [String] {
            if rest.hasPrefix("["), let d = rest.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [String] { return a }
            return ["/bin/sh", "-c", rest]
        }
        for line in changes.flatMap({ $0.split(separator: "\n").map(String.init) }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let cmd = t[..<sp].uppercased()
            let rest = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            switch cmd {
            case "CMD": cfg.Cmd = list(rest)
            case "ENTRYPOINT": cfg.Entrypoint = list(rest)
            case "ENV":
                var pairs: [String] = []
                if rest.contains("="), rest.split(separator: " ").allSatisfy({ $0.contains("=") }) {
                    pairs = rest.split(separator: " ").map(String.init)
                } else if let s = rest.firstIndex(of: " ") { pairs = [String(rest[..<s]) + "=" + rest[rest.index(after: s)...].trimmingCharacters(in: .whitespaces)] }
                cfg.Env = mergeEnv(cfg.Env ?? [], pairs.map { $0.replacingOccurrences(of: "\"", with: "") })
            case "EXPOSE":
                var m = cfg.ExposedPorts ?? [:]
                for p in rest.split(separator: " ") { m[p.contains("/") ? String(p) : "\(p)/tcp"] = EmptyStruct() }
                cfg.ExposedPorts = m
            case "LABEL":
                var l = cfg.Labels ?? [:]
                for p in rest.split(separator: " ") { let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { l[String(kv[0])] = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
                cfg.Labels = l
            case "USER": cfg.User = rest
            case "VOLUME":
                var v = cfg.Volumes ?? [:]
                let items = rest.hasPrefix("[") ? list(rest) : rest.split(separator: " ").map(String.init)
                for i in items { v[i] = EmptyStruct() }
                cfg.Volumes = v
            case "WORKDIR": cfg.WorkingDir = rest
            default: break
            }
        }
    }
}
