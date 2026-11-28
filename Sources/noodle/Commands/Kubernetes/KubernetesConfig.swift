import Foundation
import NoodleCore

enum K8s {
    /// The official k3s image, pinned by the digest of its multi-arch index (pulling by digest makes the engine
    /// verify every byte against it). Update both lines together.
    static let version = "v1.37.2+k3s1"
    static let image = "rancher/k3s@sha256:21ea6e0fac4e3930c2ce8aa40ddd41a8b18cb3e9a0222c030dc005e7e88c4332"
    static let container = "noodle-k3s"
    static let volume = "noodle-k3s-data"
    /// k3s exits when its node address changes, and the engine hands out addresses round-robin, so the
    /// node gets a network of its own and a fixed address.
    static let network = "noodle-k3s-net"
    static let subnet = "172.31.250.0/24"
    static let nodeIP = "172.31.250.2"
    static let defaultAPIPort = 6443
    /// Optional, explicit TCP publications for NodePorts. LoadBalancer ports are discovered at runtime.
    static let defaultPorts = ""
    static let contextName = "noodle"
    static let labelPrefix = "dev.noodle.kubernetes."

    static func directory(_ p: NoodlePaths) -> URL { p.root.appendingPathComponent("kubernetes", isDirectory: true) }
    static func kubeconfig(_ p: NoodlePaths) -> URL { directory(p).appendingPathComponent("kubeconfig") }

    /// "8080-8089,8443" -> [8080...8089, 8443]; nil on a bad entry. Ports 1...65535, at most 256 in total.
    static func parsePorts(_ spec: String) -> [Int]? {
        var out: [Int] = []
        for part in spec.split(separator: ",", omittingEmptySubsequences: true) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard ends.count <= 2, ends.allSatisfy({ $0 != nil }) else { return nil }
            let lo = ends[0]!, hi = ends.last!!
            guard lo >= 1, hi <= 65535, lo <= hi else { return nil }
            out += Array(lo...hi)
        }
        guard out.count <= 256 else { return nil }
        var seen = Set<Int>()
        return out.filter { seen.insert($0).inserted }
    }

    /// k3s names its single context, cluster and user "default"; the isolated file calls all of them "noodle".
    static func rename(kubeconfig text: String, server: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            let indent = String(line.prefix(while: { $0 == " " }))
            if t.hasPrefix("server:") { return indent + "server: " + server }
            for key in ["name:", "cluster:", "user:", "current-context:"] where t == key + " default" || t == "- " + key + " default" {
                let dash = t.hasPrefix("- ") ? "- " : ""
                return indent + dash + key + " " + contextName
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// The value of a `key: value` line, first match.
    static func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + ":") { return t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}
