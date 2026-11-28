import Foundation
import Testing

@testable import noodle

@Suite("JSONOutput")
struct JSONOutputTests {
    private func decode(_ doc: [String: Any]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(jsonLine(doc).utf8)) as? [String: Any])
    }

    private let row = RunnerRepoRow(repo: "o/r", kinds: "linux+macos", mode: "on", lastJob: ("build", nil, "u"))

    @Test func everyDocumentCarriesSchemaVersionAndDecodes() throws {
        let docs: [[String: Any]] = [
            doctorJSON(issues: [("dead socket", true)], unresolved: 0, repairable: 1),
            toolsStatusJSON([("docker", "29.9.3", true)]),
            updateCheckJSON(currentBuild: 7, version: nil, build: nil),
            updateStatusJSON(phase: nil, version: nil, build: nil, launchAttempts: nil),
            machineStatusJSON(MachineStatusFields(name: "dev", state: "running", image: "ubuntu", user: "me", cpus: 2,
                                                  memoryMiB: 2048, diskGiB: 20, systemd: true, share: nil, pid: 42, address: "10.0.0.2")),
            kubernetesStartJSON(alreadyRunning: false, apiPort: 6443, kubeconfig: "/k", ports: ""),
            startupStatusJSON(vmRunning: true, guestAgentReady: false),
            diagnosticsJSON(path: "/tmp/d.tar.gz", entries: ["a"]),
            diagnosticsListJSON([("a", nil)]),
            runnersListJSON([row]),
            runnersStatusJSON(on: false, repos: 0, running: [], awake: false, message: nil),
            runnersReposJSON([("o/r", true)]),
            runnersCheckJSON(repo: "o/r", workflows: [("ci.yml", ["line"])]),
        ]
        for doc in docs { #expect(try decode(doc)["schemaVersion"] as? Int == 1) }
    }

    @Test func fixturesKeepTheirShape() throws {
        let doctor = try decode(doctorJSON(issues: [("dead socket", false)], unresolved: 1, repairable: 0))
        #expect(doctor["healthy"] as? Bool == false)
        #expect((doctor["issues"] as? [[String: Any]])?.first?["message"] as? String == "dead socket")
        let update = try decode(updateCheckJSON(currentBuild: 7, version: "1.2", build: 8))
        #expect(update["updateAvailable"] as? Bool == true)
        let listed = try decode(runnersListJSON([RunnerRepoRow(repo: "o/r", kinds: "linux+macos", mode: "on", lastJob: nil)]))
        let repo = try #require((listed["repos"] as? [[String: Any]])?.first)
        #expect(repo["kinds"] as? [String] == ["linux", "macos"])
        #expect(repo["lastJob"] is NSNull)
        #expect(listed["hold"] is NSNull)
        let held = try decode(runnersStatusJSON(on: true, repos: 1, running: [], awake: true, message: nil, hold: "Held: on battery"))
        #expect((held["startFailures"] as? [Any])?.isEmpty == true)
        #expect(held["hold"] as? String == "Held: on battery")
        let wrapped = encodableJSON(["a", "b"], key: "findings")
        #expect(wrapped["schemaVersion"] as? Int == 1 && (wrapped["findings"] as? [String]) == ["a", "b"])
    }

    @Test func slashesStayUnescapedInEveryForm() {
        #expect(jsonLine(["url": "http://a/b"]) == #"{"url":"http://a/b"}"#)
        #expect(jsonLine(["path": "/x"], pretty: true).contains(#""/x""#))
        struct Row: Encodable { let path = "/Users/demo" }
        #expect(jsonLine(encoding: Row()) == #"{"path":"/Users/demo"}"#)
    }

    @Test func jsonFlagBelongsToNoodleOnlyBeforeTheLaunchedProgram() {
        #expect(ownArguments(["status", "--json"]).contains("--json"))
        #expect(!ownArguments(["machine", "shell", "dev", "--", "tool", "--json"]).contains("--json"))
        #expect(!ownArguments(["dev", "api", "node", "server.js", "--json"]).contains("--json"))
        #expect(!ownArguments(["debug", "run", "alpine", "app", "--json"]).contains("--json"))
        #expect(ownArguments(["debug", "run"]) == ["debug", "run"])
    }
}
