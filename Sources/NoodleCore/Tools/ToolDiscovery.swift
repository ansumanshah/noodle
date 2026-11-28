import Foundation

/// Finds Docker client tools already on this Mac so first-use setup downloads only what is missing.
/// It never installs or changes anything. Used by the CLI (`noodle setup`) and the app terminal.
public struct ToolDiscovery: Sendable {
    public let env: [String: String]
    public let home: String
    public let dockerConfig: String
    public let paths: NoodlePaths

    public init(env: [String: String] = ProcessInfo.processInfo.environment, paths: NoodlePaths) {
        self.env = env
        self.home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        self.dockerConfig = env["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.docker"
        self.paths = paths
    }

    // MARK: candidates

    /// Where a tool might live. Noodle's own tools folder is included only when `includeManaged`.
    public func candidates(_ name: String, includeManaged: Bool) -> [String] {
        let fm = FileManager.default
        var dirs = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? fm.currentDirectoryPath : String($0) }
        dirs += [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                 dockerConfig + "/cli-plugins", home + "/.docker/cli-plugins"]
        for prefix in ["/opt/homebrew", "/usr/local"] {
            dirs += [prefix + "/lib/docker/cli-plugins", prefix + "/libexec/docker/cli-plugins",
                     prefix + "/opt/" + name + "/bin", prefix + "/opt/" + name + "/lib/docker/cli-plugins"]
        }
        let mise = env["MISE_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ((env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share") + "/mise")
        let installs = mise + "/installs"
        for tool in ((try? fm.contentsOfDirectory(atPath: installs)) ?? []).sorted() {
            // mise backends can name tools docker, docker-cli, or namespace them (e.g. aqua-docker-cli).
            guard tool.contains("docker") || tool.contains("compose") || tool.contains("buildx") else { continue }
            let root = installs + "/" + tool
            for version in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted().reversed() {
                let base = root + "/" + version
                dirs += [base + "/bin", base, base + "/cli-plugins", base + "/lib/docker/cli-plugins"]
            }
        }
        let managed = [Tools.directory(paths).path, Tools.pluginDirectory(paths).path]
        let managedSet = Set(managed.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if includeManaged { dirs += managed }
        else { dirs.removeAll { managedSet.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) } }
        // Preserve existing preferences, then look for plugins shipped with Docker Desktop.
        if Tools.pluginNames.contains(name) {
            dirs += ["/usr/local/cli-plugins", "/Applications/Docker.app/Contents/Resources/cli-plugins"]
        }
        var seen = Set<String>()
        return dirs.map { $0 + "/" + name }.filter { seen.insert($0).inserted }
    }

    // MARK: compatibility

    /// Version floors: docker 20, compose 2, buildx 0.10. Output must also name the right program.
    public static func versionOK(_ name: String, output: String) -> Bool {
        let text = output.lowercased()
        let pattern: String
        switch name {
        case "docker":
            guard text.contains("docker version") else { return false }
            pattern = #"version\s+v?(\d+)\.(\d+)"#
        case "docker-compose":
            guard text.contains("docker compose version") else { return false }
            pattern = #"version\s+v?(\d+)\.(\d+)"#
        case "docker-buildx":
            guard text.contains("buildx") else { return false }
            pattern = #"\sv?(\d+)\.(\d+)"#
        case "docker-model":
            guard text.contains("client:"), text.contains("os/arch:"), text.contains("server:") else { return false }
            pattern = #"client:\s*version:\s*v?(\d+)\.(\d+)"#
        default: return false
        }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let major = Int(text[majorRange]), let minor = Int(text[minorRange]) else { return false }
        switch name {
        case "docker": return major >= 20
        case "docker-compose": return major >= 2
        case "docker-model": return major >= 1
        default: return major > 0 || minor >= 10
        }
    }

    /// Runs the binary itself. A tool that fails, hangs or prints the wrong thing is not compatible.
    public func compatible(_ path: String, name: String) -> Bool {
        let file = URL(fileURLWithPath: path)
        if isStubCandidate(file, name: name) { return stubReady(file, name: name) }
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        if name == Tools.modelPlugin {
            guard let result = exec(path, ["docker-cli-plugin-metadata"]), result.code == 0,
                  let data = result.out.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode([String: String].self, from: data),
                  metadata["SchemaVersion"] == "0.1.0", metadata["Vendor"] == "Docker Inc.",
                  metadata["ShortDescription"] == "Docker Model Runner",
                  let version = metadata["Version"] else { return false }
            return Self.versionOK(name, output: "Client:\n Version: \(version)\n OS/Arch: darwin/arm64\nServer:")
        }
        guard let result = exec(path, name == "docker" ? ["--version"] : ["version"]), result.code == 0 else { return false }
        return Self.versionOK(name, output: result.out)
    }

    /// Whether `docker` itself resolves the plugin (`docker compose version`) with this Docker config.
    public func plugin(_ name: String, worksUnder docker: String) -> Bool {
        let file = URL(fileURLWithPath: dockerConfig).appendingPathComponent("cli-plugins/" + name)
        if isStubCandidate(file, name: name) { return stubReady(file, name: name) }
        let sub = String(name.dropFirst("docker-".count))
        guard let result = exec(docker, [sub, "version"]), result.code == 0 else { return false }
        return Self.versionOK(name, output: result.out)
    }

    public func lazyPlugin(_ name: String) -> String? {
        let path = URL(fileURLWithPath: dockerConfig).appendingPathComponent("cli-plugins/" + name)
        return stubReady(path, name: name) ? path.path : nil
    }

    private var receipt: [String: String] {
        guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("setup.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func isStubCandidate(_ file: URL, name: String) -> Bool {
        LazyToolPlugin.isStub(file, name: name) || LazyToolPlugin.ownsStub(file, name: name, paths: paths, receipt: receipt)
    }

    private func stubReady(_ file: URL, name: String) -> Bool {
        LazyToolPlugin.ready(file, name: name, paths: paths, home: home, receipt: receipt)
    }

    // MARK: lookup

    /// A compatible tool outside Noodle's tools folder.
    public func external(_ name: String) -> String? {
        candidates(name, includeManaged: false).first { compatible($0, name: name) }
    }

    /// The docker CLI to run: one found on this Mac, else Noodle's own downloaded copy.
    public func docker() -> String? {
        candidates("docker", includeManaged: true).first { compatible($0, name: "docker") }
    }

    private func exec(_ path: String, _ args: [String]) -> (code: Int32, out: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var environment = env
        environment["DOCKER_CONFIG"] = dockerConfig
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
