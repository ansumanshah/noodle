import Foundation
import NoodleCore

/// Select the caller's Docker endpoint without changing any Docker or model context on disk.
func prepareModelToolEnvironment(original: [String]) {
    guard (env["MODEL_RUNNER_HOST"] ?? "").isEmpty else { return }
    var context: String?
    var host: String?
    var config = dockerConfigDirectory.path
    var index = 0
    while index < original.count {
        let argument = original[index]
        if ["-c", "--context", "-H", "--host", "--config"].contains(argument) {
            guard index + 1 < original.count else { return }
            index += 1
            if argument == "--config" { config = original[index] }
            else if argument == "-c" || argument == "--context" { context = original[index] }
            else { host = original[index] }
        } else if argument.hasPrefix("--context=") { context = String(argument.dropFirst(10)) }
        else if argument.hasPrefix("--host=") { host = String(argument.dropFirst(7)) }
        else if argument.hasPrefix("--config=") { config = String(argument.dropFirst(9)) }
        else if argument.hasPrefix("-H"), argument.count > 2 { host = String(argument.dropFirst(2)) }
        else if argument == "-D" || argument == "--debug" { /* unrelated Docker root option */ }
        else { break }
        index += 1
    }
    var command = Array(original.dropFirst(index))
    if command.first == "model" { command.removeFirst() }
    if command.isEmpty || command.contains("--help") || ["version", "help", "context"].contains(command.first ?? "") { return }
    let contexts = URL(fileURLWithPath: config).appendingPathComponent("model/contexts.json")
    if let bytes = try? Data(contentsOf: contexts),
       let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
       let active = state["current"] as? String, !active.isEmpty, active != "default" { return }

    context = context ?? env["DOCKER_CONTEXT"].flatMap { $0.isEmpty ? nil : $0 }
    host = host ?? env["DOCKER_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    if context == nil && host == nil {
        let file = URL(fileURLWithPath: config).appendingPathComponent("config.json")
        if let bytes = try? Data(contentsOf: file), let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            context = state["currentContext"] as? String
        }
    }
    if let selected = context, !selected.isEmpty {
        guard let docker = discoveredDocker() else { return }
        let result = run(docker, ["--config", config, "context", "inspect", selected, "--format", "{{json .Endpoints.docker.Host}}"])
        guard result.code == 0, let bytes = result.out.data(using: .utf8),
              let endpoint = try? JSONDecoder().decode(String.self, from: bytes) else { return }
        host = endpoint
    }
    guard let host, host.hasPrefix("unix://") else { return }
    let selectedSocket = String(host.dropFirst(7))
    let client = DockerHTTP(socketPath: selectedSocket)
    let reply: HTTPReply
    do { reply = try client.request("GET", "/noodle/model-runner/connection") }
    catch {
        if selectedSocket == socketPath { die("cannot reach Noodle's model endpoint; start noodled before running docker model") }
        return
    }
    guard reply.status == 200 else {
        let info = try? client.request("GET", "/info")
        let identity = info.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        if selectedSocket == socketPath || identity?["OperatingSystem"] as? String == "Noodle" {
            die("Noodle's model endpoint is unavailable; update the daemon and retry")
        }
        return
    }
    guard let connection = try? JSONDecoder().decode(ModelRunnerConnection.self, from: reply.body),
          let endpoint = URLComponents(string: connection.host), endpoint.scheme == "http", endpoint.host == "host.docker.internal",
          let port = endpoint.port, connection.proxy == "http://127.0.0.1:\(port)", endpoint.path.hasPrefix("/model-runner/") else {
        die("Noodle returned an invalid Model Runner connection")
    }
    for (name, value) in connection.environment { setenv(name, value, 1) }
    // Go refuses HTTP_PROXY in CGI environments. This process is a local CLI, not a CGI handler.
    unsetenv("REQUEST_METHOD")
}
