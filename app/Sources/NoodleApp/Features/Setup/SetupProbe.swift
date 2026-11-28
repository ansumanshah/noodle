import Foundation
import NoodleCore

/// Read-only looks at this Mac for the setup sheet. Blocking, so callers run it off the main actor.
/// Nothing here installs, starts or changes anything.
enum SetupProbe {
    static let tools = ["docker", "docker-compose", "docker-buildx"]

    static func discovery(_ paths: NoodlePaths) -> ToolDiscovery { ToolDiscovery(paths: paths) }

    static func detectTools(_ paths: NoodlePaths) -> [SetupTool] {
        guard !Task.isCancelled else { return [] }
        let found = discovery(paths)
        let docker = found.docker()
        return tools.map { name in
            if Task.isCancelled { return SetupTool(name: name, path: nil) }
            if name == "docker" { return SetupTool(name: name, path: docker, version: docker.flatMap { version($0, ["--version"]) }) }
            if let stub = found.lazyPlugin(name) { return SetupTool(name: name, path: stub) }
            if let docker, found.plugin(name, worksUnder: docker) {
                // The plugin file docker loads, else the docker command that provides it.
                let file = found.candidates(name, includeManaged: true).first { FileManager.default.fileExists(atPath: $0) }
                return SetupTool(name: name, path: file ?? docker, version: version(docker, [String(name.dropFirst(7)), "version"]))
            }
            let path = found.candidates(name, includeManaged: true).first { found.compatible($0, name: name) }
            return SetupTool(name: name, path: path, version: path.flatMap { version($0, ["version"]) })
        }
    }

    /// Runs a tool that already passed discovery and reads the version it prints.
    static func version(_ path: String, _ args: [String]) -> String? {
        if Tools.pins.contains(where: { LazyToolPlugin.isStub(URL(fileURLWithPath: path), name: $0.name) }) { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SetupTool.parseVersion(String(decoding: data, as: UTF8.self))
    }

    /// Tagged images, volumes and stopped containers, as `noodle import` would copy them.
    static func inventory(_ api: DockerAPI) async -> ImportInventory? {
        guard let images = try? await api.images(), let volumes = try? await api.volumes(),
              let containers = try? await api.containers() else { return nil }
        return ImportInventory(images: images.filter { !$0.repoTags.isEmpty }.count, volumes: volumes.count,
                               containers: containers.filter { ["exited", "created"].contains($0.state) }.count)
    }

    /// Other engines' Docker contexts, with sockets that exist on disk. Reachability comes later.
    static func contexts(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (current: String, list: [(name: String, socket: String)]) {
        let config = dockerContexts(environment)
        var list = config.endpoints.compactMap { endpoint -> (name: String, socket: String)? in
            guard endpoint.name != "noodle", let socket = try? ImportNaming.socketPath(host: endpoint.host) else { return nil }
            return (endpoint.name, socket)
        }
        let host = environment["DOCKER_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? "unix:///var/run/docker.sock"
        let hostSocket = try? ImportNaming.socketPath(host: host)
        let current = SetupPlan.currentContext(environment: environment, saved: config.current, hostSocket: hostSocket, contexts: list)
        // One engine is listed once: the named context that owns the socket stands in for "default".
        if let hostSocket, !list.contains(where: { $0.name == current && $0.socket == hostSocket }) { list.append(("default", hostSocket)) }
        return (current, list.filter { FileManager.default.fileExists(atPath: $0.socket) })
    }

    static func dockerTarget(noodleSocket: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let config = dockerContexts(environment)
        let context = environment["DOCKER_CONTEXT"].flatMap { $0.isEmpty ? nil : $0 }
        let host = environment["DOCKER_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        let name = context ?? (host == nil ? config.current : nil) ?? "default"
        let endpoint = name == "default" ? host ?? "unix:///var/run/docker.sock"
            : config.endpoints.first { $0.name == name }?.host
        guard let endpoint else { return "Unknown context" }
        func localPath(_ endpoint: String) -> String? {
            guard let socket = try? ImportNaming.socketPath(host: endpoint), socket.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: socket).resolvingSymlinksInPath().path
        }
        if let socket = localPath(endpoint), socket == localPath(noodleSocket) { return "Noodle" }
        if name != "default" { return name == "noodle" ? "noodle (other socket)" : name }
        if let named = config.endpoints.first(where: { $0.name != "noodle" && $0.host == endpoint }) { return named.name }
        return host != nil ? "Custom host" : "Default context"
    }

    static func dockerContexts(_ environment: [String: String])
        -> (current: String?, endpoints: [(name: String, host: String)]) {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let config = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.docker"
        var saved: String?
        if let data = FileManager.default.contents(atPath: config + "/config.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            saved = json["currentContext"] as? String
        }
        var endpoints: [(name: String, host: String)] = []
        let meta = config + "/contexts/meta"
        for dir in ((try? FileManager.default.contentsOfDirectory(atPath: meta)) ?? []).sorted() {
            guard let data = FileManager.default.contents(atPath: meta + "/" + dir + "/meta.json"),
                  let context = ImportNaming.contextHost(metaJSON: data) else { continue }
            endpoints.append(context)
        }
        return (saved.flatMap { $0.isEmpty ? nil : $0 }, endpoints)
    }

    /// The startup files this shell may read, by name, for the ones that exist.
    static func startupTexts(home: String, shell: String) -> [String: String] {
        var files: [String: String] = [:]
        for name in SetupPlan.startupFiles(shell: shell) {
            if let text = try? String(contentsOfFile: home + "/" + name, encoding: .utf8) { files[name] = text }
        }
        return files
    }

    static func pathNeeded(home: String, shell: String) -> Bool {
        SetupPlan.pathNeeded(shell: shell, files: startupTexts(home: home, shell: shell))
    }

    /// DOCKER_CONTEXT or DOCKER_HOST, from this environment or a startup file.
    static func dockerOverride(home: String, shell: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SetupPlan.dockerOverride(environment: environment, profileTexts: SetupPlan.loginTexts(shell: shell, files: startupTexts(home: home, shell: shell)))
    }

    /// Removes work folders of tools downloads whose process is gone, such as one the person cancelled.
    static func clearPartialDownloads(_ paths: NoodlePaths) {
        let fm = FileManager.default
        let root = Tools.directory(paths).path
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where dir.hasPrefix(".download-") {
            guard let owner = pid_t(dir.dropFirst(".download-".count)), kill(owner, 0) != 0, errno == ESRCH else { continue }
            try? fm.removeItem(atPath: root + "/" + dir)
        }
    }

    /// The environment for docker commands that must reach Noodle whatever context is selected.
    static func dockerEnvironment(socket: String) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for key in ["DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"] { result[key] = nil }
        result["DOCKER_HOST"] = "unix://" + socket
        return result
    }

    /// Final size of each download, from a HEAD request. Missing when the server does not say.
    static func downloadSize(_ url: String) async -> Int64? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request), response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength
    }

    static func downloadFiles(_ paths: NoodlePaths) -> [String: Int64] {
        let fm = FileManager.default
        let root = Tools.directory(paths).path
        var sizes: [String: Int64] = [:]
        for dir in ((try? fm.contentsOfDirectory(atPath: root)) ?? []) where dir.hasPrefix(".download-") {
            for file in ((try? fm.contentsOfDirectory(atPath: root + "/" + dir)) ?? []) {
                let size = (try? fm.attributesOfItem(atPath: root + "/" + dir + "/" + file)[.size] as? NSNumber)?.int64Value ?? 0
                sizes[file] = max(sizes[file] ?? 0, size)
            }
        }
        return sizes
    }
}
