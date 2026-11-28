import Foundation
import Observation

struct KubernetesSnapshot: Decodable, Equatable, Sendable {
    var daemonRunning: Bool
    var exists: Bool
    var running: Bool
    var ready: Bool
    var hasData: Bool
    var version: String
    var apiPort: Int
    var ports: [Int]
    var kubeconfig: String
    var hasKubeconfig: Bool
    var pods: [KubernetesPod]
    var podsError: String

    var state: String {
        if !daemonRunning { return "Engine stopped" }
        if !exists { return "Not enabled" }
        if !running { return "Stopped" }
        return ready ? "Running" : "Starting"
    }
}

struct KubernetesPod: Decodable, Equatable, Identifiable, Sendable {
    var namespace: String
    var name: String
    var phase: String
    var ready: String
    var restarts: Int
    var id: String { namespace + "/" + name }
}

@MainActor @Observable
final class KubernetesStore {
    enum Action: String, Identifiable {
        case start, stop, reset, remove, context
        var id: String { rawValue }
        var progress: String {
            switch self {
            case .start: "Starting Kubernetes…"
            case .stop: "Stopping Kubernetes…"
            case .reset: "Resetting Kubernetes…"
            case .remove: "Removing Kubernetes…"
            case .context: "Updating kubeconfig context…"
            }
        }
    }

    private(set) var snapshot: KubernetesSnapshot?
    private(set) var action: Action?
    private(set) var refreshing = false
    private(set) var statusError: String?
    var message: String?
    private let demo: Bool

    init() {
        let demo = AppEnvironment.shared.demo
        self.demo = demo
        if demo { snapshot = DemoKubernetes.initial }
    }

    func watch() async {
        guard !demo else { return }
        await poll(every: .seconds(10)) { await refresh() }
    }

    func refresh() async {
        guard !demo, action == nil, !refreshing, !Task.isCancelled else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await CLI.run(["kubernetes", "status", "--json"], timeout: 75)
        guard !Task.isCancelled else { return }
        guard result.code == 0 else {
            statusError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        do {
            let value = try JSONDecoder().decode(KubernetesSnapshot.self, from: Data(result.output.utf8))
            Motion.animate { snapshot = value; statusError = nil }
        } catch {
            statusError = "Could not read Kubernetes status. Check that the app and noodle CLI are the same version."
        }
    }

    func perform(_ requested: Action) async {
        guard action == nil, !refreshing, statusError == nil, let current = snapshot,
              current.daemonRunning else { return }
        action = requested
        message = nil
        if demo {
            Motion.animate { snapshot = DemoKubernetes.applying(requested, to: current) }
            if requested == .context { message = "The noodle context is now current (demo)." }
        } else {
            let result: CLI.Result
            switch requested {
            case .start:
                result = await CLI.run(["kubernetes", "start"], timeout: 1500)
            case .stop:
                result = await CLI.run(["kubernetes", "stop"], timeout: 120)
            case .remove:
                result = await CLI.run(["kubernetes", "delete", "--yes"], timeout: 240)
            case .context:
                result = await CLI.run(["kubernetes", "use-context"], timeout: 60)
            case .reset:
                let deleted = await CLI.run(["kubernetes", "delete", "--yes"], timeout: 240)
                if deleted.code == 0 {
                    result = await CLI.run(["kubernetes", "start", "--api-port", String(current.apiPort),
                                            "--ports", current.ports.map(String.init).joined(separator: ",")], timeout: 1500)
                } else { result = deleted }
            }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = output.isEmpty ? (result.code == 0 ? "Done." : "Command failed (\(result.code)).") : output
        }
        action = nil
        await refresh()
    }
}
