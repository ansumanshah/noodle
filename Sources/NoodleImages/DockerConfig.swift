import Foundation

public struct RegistryCredential: Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var identityToken: String?
    public init(username: String? = nil, password: String? = nil, identityToken: String? = nil) {
        self.username = username; self.password = password; self.identityToken = identityToken
    }
}

/// Reads `~/.docker/config.json` (read only): `auths`, `credsStore`, `credHelpers`.
/// Never writes. Credential helpers are executed as `docker-credential-<name> get`.
public struct DockerConfig: Sendable {
    struct File: Decodable {
        struct Auth: Decodable { var auth: String?; var username: String?; var password: String?; var identitytoken: String? }
        var auths: [String: Auth]?
        var credsStore: String?
        var credHelpers: [String: String]?
    }
    /// Re-read on every lookup so a later `docker login` or `logout` takes effect without restarting the daemon.
    var configFile: URL
    var helperSearchPaths: [String]
    var file: File? {
        (try? Data(contentsOf: configFile)).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
    }

    public init(configDir: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let dir: URL
        if let configDir { dir = configDir }
        else if let d = environment["DOCKER_CONFIG"], !d.isEmpty { dir = URL(fileURLWithPath: d) }
        else { dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker") }
        configFile = dir.appendingPathComponent("config.json")
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin",
                      NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.docker/bin"] where !paths.contains(extra) {
            paths.append(extra)
        }
        helperSearchPaths = paths
    }

    /// Keys under which Docker stores a registry's credentials.
    static func serverKeys(for host: String) -> [String] {
        if host == ImageReference.hubRegistryHost || host == ImageReference.hubDomain || host == "index.docker.io" {
            return ["https://index.docker.io/v1/", "index.docker.io", "docker.io", "registry-1.docker.io"]
        }
        return [host, "https://" + host, "http://" + host]
    }

    public func credential(forRegistry host: String) async -> RegistryCredential? {
        guard let file = self.file else { return nil }
        let keys = Self.serverKeys(for: host)
        // 1. per-host helper
        for k in keys {
            if let helper = file.credHelpers?[k], let c = await runHelper(helper, server: k == host ? keys[0] : k) { return c }
        }
        // 2. inline auths
        for k in keys {
            if let a = file.auths?[k] {
                if let t = a.identitytoken, !t.isEmpty { return RegistryCredential(username: a.username, identityToken: t) }
                if let b64 = a.auth, let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8),
                   let colon = s.firstIndex(of: ":") {
                    return RegistryCredential(username: String(s[..<colon]), password: String(s[s.index(after: colon)...]))
                }
                if let u = a.username, let p = a.password { return RegistryCredential(username: u, password: p) }
            }
        }
        // 3. global store
        if let store = file.credsStore, !store.isEmpty {
            for k in keys { if let c = await runHelper(store, server: k) { return c } }
        }
        return nil
    }

    private func locateHelper(_ name: String) -> String? {
        let exe = "docker-credential-" + name
        for dir in helperSearchPaths {
            let p = dir + "/" + exe
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func runHelper(_ name: String, server: String) async -> RegistryCredential? {
        guard let exe = locateHelper(name) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<RegistryCredential?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["get"]
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                inPipe.fileHandleForWriting.write(Data(server.utf8))
                try? inPipe.fileHandleForWriting.close()
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0,
                      let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else { cont.resume(returning: nil); return }
                let user = obj["Username"] as? String ?? ""
                let secret = obj["Secret"] as? String ?? ""
                if user == "<token>" { cont.resume(returning: RegistryCredential(identityToken: secret)) }
                else if secret.isEmpty { cont.resume(returning: nil) }
                else { cont.resume(returning: RegistryCredential(username: user, password: secret)) }
            }
        }
    }
}
