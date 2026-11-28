import Foundation
import NoodleCore

private var modelUsage: String { CommandTable.groupHelp("model") }

func cmdModel(_ args: [String]) {
    let store = modelStore()
    let runner = ModelRunner(store: store)
    func printJSON(_ value: some Encodable) { out(jsonLine(encoding: value)) }
    do {
        switch args {
        case [], ["help"], ["--help"], ["-h"]:
            out(modelUsage)
        case ["list"], ["list", "--json"], ["catalog"], ["catalog", "--json"]:
            let entries = store.list(includeCatalog: args[0] == "catalog")
            if args.contains("--json") {
                printJSON(entries)
            } else {
                for entry in entries {
                    out("\(entry.id)\t\(fmtBytes(entry.bytes))\t\(entry.installed ? "installed" : "available")")
                }
            }
        case ["status"], ["status", "--json"]:
            let status = runner.status()
            if args.count == 2 {
                printJSON(status)
            } else {
                out("\(status.phase.rawValue) \(status.model ?? "") \((status.namedBaseURL ?? status.baseURL)?.absoluteString ?? "")"
                    .trimmingCharacters(in: .whitespaces))
                if status.lastCrash != nil || (status.restarts ?? 0) > 0 {
                    out("Note: the model runtime crashed (restarted \(status.restarts ?? 0) time(s)). See 'noodle model logs'.")
                }
            }
        case ["endpoint"], ["endpoint", "--json"]:
            let endpoint = try runner.endpoint()
            if args.count == 2 {
                printJSON(endpoint)
            } else {
                out("Model: \(endpoint.model)\nOpenAI base URL: \((endpoint.namedBaseURL ?? endpoint.baseURL).absoluteString)")
                if let url = endpoint.workloadBaseURL { out("Workload base URL: \(url.absoluteString)") }
                out("API key: \(endpoint.apiKey)")
                if ModelNetworkSetting.enabled(root: paths.root),
                   let address = ModelNetworkAddress.current(port: endpoint.baseURL.port ?? ModelBinding.defaultPort) {
                    out("Network base URL: \(address.name)" + (address.ip.map { "\nNetwork base URL (by address): \($0)" } ?? ""))
                }
            }
        case ["stop"]:
            try stopModelRunnerIfPresent(allModels: false)
            out("Model stopped")
        case ["location"]:
            out(ModelLocation.weights(root: paths.root).path)
        case ["location", "--reset"]:
            try ModelLocation.set(nil, root: paths.root)
            try? ModelRunner(store: modelStore()).refreshModels()
            out("Models install in \(ModelLocation.weights(root: paths.root).path)")
        case _ where args.count == 2 && args[0] == "location":
            guard !args[1].hasPrefix("-") else { throw CLIError.usage("unknown option \(args[1])\n" + modelUsage) }
            try ModelLocation.set(URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath, isDirectory: true), root: paths.root)
            try? ModelRunner(store: modelStore()).refreshModels()
            out("Models install in \(ModelLocation.weights(root: paths.root).path). Models already installed stay in their old folder.")
        case ["keep-alive"]:
            out((ModelKeepAliveSetting.savedText(root: paths.root) ?? "5m"))
        case ["keep-alive", "--reset"]:
            try ModelKeepAliveSetting.set(nil, root: paths.root)
            out("Keep-alive reset to 5m. It applies the next time a model starts.")
        case _ where args.count == 2 && args[0] == "keep-alive":
            _ = try modelKeepAlive(args[1])
            try ModelKeepAliveSetting.set(args[1], root: paths.root)
            out("Keep-alive saved as \(args[1]). It applies the next time a model starts.")
        case ["key"]:
            out(try ModelAPIKey.current(in: store.directory))
        case ["key", "--rotate"]:
            try ModelAPIKey.rotate(in: store.directory)
            let restarted = try store.withLock("operation") { try runner.restart() }
            out(restarted ? "New key saved. The model server restarted to use it; the old key no longer works."
                          : "New key saved. It applies the next time a model starts; the old key no longer works.")
        case ["network"], ["network", "--json"]:
            let on = ModelNetworkSetting.enabled(root: paths.root)
            let port = runner.status().baseURL?.port ?? ModelBinding.defaultPort
            let address = on ? ModelNetworkAddress.current(port: port) : nil
            if args.count == 2 {
                printJSON(ModelNetworkAddress.Report(enabled: on, url: address?.name, ipURL: address?.ip))
            } else if on {
                out("on \(address?.name ?? "")")
            } else { out("off") }
        case ["network", "on"], ["network", "off"]:
            let on = args[1] == "on"
            try ModelNetworkSetting.set(on, root: paths.root)
            let restarted = try store.withLock("operation") { try runner.restart() }
            out("Other devices \(on ? "can now" : "can no longer") use your models" + (on ? " with your key (noodle model key)." : ".")
                + (restarted ? " The model server restarted." : " It applies the next time a model starts."))
        case ["logs"]:
            guard FileManager.default.fileExists(atPath: runner.log.path) else {
                throw CLIError("there is no model runner log yet")
            }
            let result = run("/usr/bin/tail", ["-n", "80", runner.log.path])
            guard result.code == 0 else { throw CLIError(result.out) }
            out(result.out)
        default:
            guard args.count >= 2 else { die(modelUsage, code: 2) }
            let takesID = ["pull", "run", "serve", "rm"].contains(args[0])
            if takesID, args[1].hasPrefix("-") { throw CLIError.usage("unknown option \(args[1])\n" + modelUsage) }
            let id: String
            if takesID, args[1].hasPrefix("hf.co/") {
                do { id = try LocalModelHuggingFace.Reference(args[1]).id } catch { throw CLIError.usage(error.localizedDescription) }
            } else { id = args[1] }
            switch args[0] {
            case "pull" where args.count == 2:
                try store.withLock("operation") {
                    try store.pull(id)
                    try? runner.refreshModels()
                }
                out("Installed \(id)")
            case "pull" where args.count == 3 && args[2] == "--progress-json":
                try store.withLock("operation") {
                    try store.pull(id, report: emitModelPullProgress)
                    try? runner.refreshModels()
                }
            case "run":
                let (remaining, keepAlive) = try modelKeepAliveOptions(Array(args.dropFirst(2)))
                guard remaining.count <= 1 else { throw CLIError.usage(modelUsage) }
                // A prompt may start with "-" ("-5 + 3"); only a long option is rejected.
                if let flag = remaining.first, flag.hasPrefix("--") { throw CLIError.usage("unknown option \(flag)\n" + modelUsage) }
                try runner.ensureRunning(id, keepAlive: keepAlive)
                try modelChat(runner, model: id, prompt: remaining.first)
            case "import" where args.count == 3:
                let file = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
                try store.withLock("operation") {
                    try store.importWeights(file, as: args[2])
                    try? runner.refreshModels()
                }
                out("Installed \(args[2])")
            case "rm" where args.count == 2:
                try store.withLock("operation") { try runner.remove(id) }
                out("Removed \(id)")
            case "serve":
                let (remaining, keepAlive) = try modelKeepAliveOptions(Array(args.dropFirst(2)))
                let binding = try ModelBinding(arguments: remaining[...])
                let status = try store.withLock("operation") {
                    try runner.serve(id, host: binding.host, port: binding.port, keepAlive: keepAlive)
                }
                out("Serving \(id) at \((status.namedBaseURL ?? status.baseURL)?.absoluteString ?? "")")
            case "_exec" where args.count == 2:
                try runner.launch(id)
            default:
                die(modelUsage, code: 2)
            }
        }
    } catch {
        die(error.localizedDescription, code: exitCode(for: error))
    }
}

private func emitModelPullProgress(_ progress: LocalModelPullProgress) {
    guard var line = try? JSONEncoder().encode(progress) else { return }
    line.append(10)
    FileHandle.standardOutput.write(line)
}

private func modelKeepAliveOptions(_ arguments: [String]) throws -> ([String], LocalModelKeepAlive?) {
    var remaining: [String] = []
    var duration: String?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--keep-alive" || argument.hasPrefix("--keep-alive=") {
            guard duration == nil else { throw CLIError.usage("--keep-alive may only be specified once") }
            if argument == "--keep-alive" {
                index += 1
                guard index < arguments.count else { throw CLIError.usage("--keep-alive needs a duration, for example 5m") }
                duration = arguments[index]
            } else { duration = String(argument.dropFirst("--keep-alive=".count)) }
        } else { remaining.append(argument) }
        index += 1
    }
    return (remaining, try (duration ?? env["NOODLE_MODEL_KEEP_ALIVE"]).map(modelKeepAlive))
}

private func modelKeepAlive(_ text: String) throws -> LocalModelKeepAlive {
    do { return try LocalModelKeepAlive(text) } catch { throw CLIError.usage(error.localizedDescription) }
}

private func modelChat(_ runner: ModelRunner, model: String, prompt: String?) throws {
    if let prompt {
        out(try runner.chat([.init(role: .user, content: prompt)], model: model))
        return
    }
    var messages: [LocalModelChat.Message] = []
    err("Chatting with \(model). Use /reset to clear the chat or /exit to leave it.")
    while true {
        if isatty(STDIN_FILENO) != 0 {
            FileHandle.standardOutput.write(Data("> ".utf8))
        }
        guard let line = readLine(), line != "/exit" else { return }
        if line == "/reset" {
            messages.removeAll()
            continue
        }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let next = messages + [.init(role: .user, content: line)]
        do {
            let answer = try runner.chat(next, model: model)
            out(answer)
            messages = next + [.init(role: .assistant, content: answer)]
        } catch {
            err(error.localizedDescription)
        }
    }
}

func modelStore() -> ModelStore {
    ModelStore(directory: paths.root.appendingPathComponent("models", isDirectory: true), customWeights: ModelLocation.custom(root: paths.root))
}

func stopModelRunnerIfPresent(allModels: Bool = true) throws {
    let store = modelStore()
    guard FileManager.default.fileExists(atPath: store.directory.path) else { return }
    try store.withLock("operation") { try ModelRunner(store: store).stop(allModels: allModels) }
}
