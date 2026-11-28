import Foundation

let podLabel = "dev.noodle.pod"
let podRoleLabel = "dev.noodle.pod.role"
let podOwnerLabel = "dev.noodle.pod.infra"
let podShareLabel = "dev.noodle.pod.share"
let podInfraImage = "alpine:3.22"
var podUsage: String { CommandTable.groupHelp("pod") }

typealias PodJSON = [String: Any]

struct PodContainer {
    let id: String
    let name: String
    let state: String
    let labels: [String: String]

    init(_ row: PodJSON) throws {
        guard let id = row["Id"] as? String, !id.isEmpty,
              let names = row["Names"] as? [String], let name = names.first,
              let state = row["State"] as? String else { throw CLIError("invalid container list reply") }
        self.id = id
        self.name = name.hasPrefix("/") ? String(name.dropFirst()) : name
        self.state = state
        labels = row["Labels"] as? [String: String] ?? [:]
    }

    var running: Bool { ["running", "paused", "restarting"].contains(state) }
}

struct Pod {
    let name: String
    let infra: PodContainer
    let members: [PodContainer]
    var containers: [PodContainer] { [infra] + members }
    var summary: PodJSON {
        ["id": infra.id, "name": name, "state": infra.state,
         "share": ["net"], "members": members.count,
         "running": containers.filter(\.running).count]
    }
}

/// All API work is synchronous on the CLI's main thread. The existing EngineEndpoint
/// bounds socket sends/receives to 300s; nothing is linked into the daemon.
func podEndpoint() -> EngineEndpoint { EngineEndpoint(name: "noodled", socketPath: socketPath) }

func podEscape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
}

func podRoute(_ container: PodContainer) -> String { "/containers/" + podEscape(container.id) }

func podList(_ endpoint: EngineEndpoint) throws -> [Pod] {
    let reply = try endpoint.call("GET", "/containers/json?all=1")
    guard let rows = try JSONSerialization.jsonObject(with: reply.body) as? [PodJSON] else {
        throw CLIError("invalid container list reply")
    }
    let containers = try rows.map { try PodContainer($0) }
    return try containers.filter { $0.labels[podRoleLabel] == "infra" && $0.labels[podLabel] != nil }.map { infra in
        guard let name = infra.labels[podLabel], infra.labels[podShareLabel] == "net" else {
            throw CLIError("pod network container \(infra.name) has unsupported or missing share metadata")
        }
        let members = containers.filter {
            $0.labels[podLabel] == name && $0.labels[podRoleLabel] == "member" && $0.labels[podOwnerLabel] == infra.id
        }.sorted { $0.name < $1.name }
        return Pod(name: name, infra: infra, members: members)
    }.sorted { $0.name < $1.name }
}

func podFind(_ reference: String, _ endpoint: EngineEndpoint) throws -> Pod {
    let pods = try podList(endpoint)
    let exact = pods.filter { $0.name == reference || $0.infra.id == reference }
    if exact.count == 1 { return exact[0] }
    let matches = exact.isEmpty ? pods.filter { $0.infra.id.hasPrefix(reference) } : exact
    guard matches.count == 1 else {
        throw CLIError(matches.isEmpty ? "No such pod: \(reference)" : "ambiguous pod: \(reference)")
    }
    return matches[0]
}
