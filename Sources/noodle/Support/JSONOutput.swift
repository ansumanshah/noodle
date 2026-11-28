import Foundation
import NoodleCore

// One JSON document per command on stdout, with `schemaVersion`. Pure builders so tests can check them against fixtures.

func jsonOut(_ document: [String: Any]) { out(jsonLine(document)) }

func doctorJSON(issues: [(message: String, fixed: Bool)], unresolved: Int, repairable: Int) -> [String: Any] {
    ["schemaVersion": 1, "healthy": issues.isEmpty, "unresolved": unresolved, "repairable": repairable,
     "issues": issues.map { ["message": $0.message, "fixed": $0.fixed] as [String: Any] }]
}

func toolsStatusJSON(_ rows: [(name: String, version: String, installed: Bool)]) -> [String: Any] {
    ["schemaVersion": 1, "tools": rows.map { ["name": $0.name, "version": $0.version, "installed": $0.installed] as [String: Any] }]
}

func updateCheckJSON(currentBuild: Int, version: String?, build: Int?) -> [String: Any] {
    ["schemaVersion": 1, "currentBuild": currentBuild, "updateAvailable": version != nil,
     "version": version as Any? ?? NSNull(), "build": build as Any? ?? NSNull()]
}

func updateStatusJSON(phase: String?, version: String?, build: Int?, launchAttempts: Int?) -> [String: Any] {
    ["schemaVersion": 1, "staged": phase != nil, "phase": phase as Any? ?? NSNull(), "version": version as Any? ?? NSNull(),
     "build": build as Any? ?? NSNull(), "launchAttempts": launchAttempts as Any? ?? NSNull()]
}

struct MachineStatusFields {
    var name, state, image, user: String
    var cpus, memoryMiB, diskGiB: Int
    var systemd: Bool
    var share: String?
    var pid: Int32?
    var address: String?
}

func machineStatusJSON(_ m: MachineStatusFields) -> [String: Any] {
    ["schemaVersion": 1, "name": m.name, "state": m.state, "image": m.image, "user": m.user, "cpus": m.cpus,
     "memoryMiB": m.memoryMiB, "diskGiB": m.diskGiB, "systemd": m.systemd, "share": m.share as Any? ?? NSNull(),
     "pid": m.pid as Any? ?? NSNull(), "address": m.address as Any? ?? NSNull()]
}

func kubernetesStartJSON(alreadyRunning: Bool, apiPort: Int, kubeconfig: String, ports: String) -> [String: Any] {
    ["schemaVersion": 1, "ready": true, "alreadyRunning": alreadyRunning, "apiServer": "https://127.0.0.1:\(apiPort)",
     "kubeconfig": kubeconfig, "nodePorts": ports]
}

func startupStatusJSON(vmRunning: Bool, guestAgentReady: Bool) -> [String: Any] {
    ["schemaVersion": 1, "dockerApi": "ready", "vmRunning": vmRunning, "guestAgentReady": guestAgentReady]
}

func diagnosticsJSON(path: String, entries: [String]) -> [String: Any] {
    ["schemaVersion": 1, "path": path, "entries": entries]
}

func diagnosticsListJSON(_ entries: [(name: String, source: String?)]) -> [String: Any] {
    ["schemaVersion": 1, "entries": entries.map { ["name": $0.name, "source": $0.source as Any? ?? NSNull()] as [String: Any] }]
}

struct RunnerRepoRow { let repo, kinds, mode: String; let lastJob: (name: String, conclusion: String?, url: String)? }

/// `startFailures`: one object per failing kind (kind, repo, at, reason, log), newest first; empty when none.
private func startFailuresJSON(_ list: [RunnerStartFailure]) -> [[String: Any]] {
    let iso = ISO8601DateFormatter()
    return list.map { ["kind": $0.kind.rawValue, "repo": $0.repo, "at": iso.string(from: $0.at),
                       "reason": $0.reason as Any? ?? NSNull(), "log": $0.log as Any? ?? NSNull()] }
}

func runnersListJSON(_ rows: [RunnerRepoRow], hold: String? = nil, startFailures: [RunnerStartFailure] = []) -> [String: Any] {
    ["schemaVersion": 1, "hold": hold as Any? ?? NSNull(), "startFailures": startFailuresJSON(startFailures), "repos": rows.map { r -> [String: Any] in
        ["repo": r.repo, "kinds": r.kinds.split(separator: "+").map(String.init), "mode": r.mode,
         "lastJob": r.lastJob.map { ["name": $0.name, "conclusion": $0.conclusion as Any? ?? NSNull(), "url": $0.url] as [String: Any] } as Any? ?? NSNull()]
    }]
}

func runnersStatusJSON(on: Bool, repos: Int, running: [String], awake: Bool, message: String?, hold: String? = nil,
                      startFailures: [RunnerStartFailure] = []) -> [String: Any] {
    ["schemaVersion": 1, "hold": hold as Any? ?? NSNull(), "startFailures": startFailuresJSON(startFailures), "on": on, "repos": repos, "running": running, "awake": awake, "message": message as Any? ?? NSNull()]
}

/// Wraps an Encodable in the one-document shape: `schemaVersion` plus its fields, or under `key` when it is an array.
func encodableJSON<T: Encodable>(_ value: T, key: String? = nil) -> [String: Any] {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value),
          let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { die("could not encode the JSON output") }
    var doc = (key == nil ? any as? [String: Any] : nil) ?? [:]
    if let key { doc[key] = any }
    doc["schemaVersion"] = 1
    return doc
}

func runnersReposJSON(_ rows: [(repo: String, isPrivate: Bool)]) -> [String: Any] {
    ["schemaVersion": 1, "repos": rows.map { ["repo": $0.repo, "private": $0.isPrivate] as [String: Any] }]
}

func runnersCheckJSON(repo: String, workflows: [(file: String, findings: [String])]) -> [String: Any] {
    ["schemaVersion": 1, "repo": repo,
     "workflows": workflows.map { ["file": $0.file, "findings": $0.findings] as [String: Any] }]
}
