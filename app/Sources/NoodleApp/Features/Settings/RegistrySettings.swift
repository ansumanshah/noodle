import Foundation
import SwiftUI

struct RegistryEntry: Hashable, Sendable {
    let name: String
    let argument: String
}

struct RegistrySnapshot: Sendable {
    let entries: [RegistryEntry]
    let incomplete: Bool

    static func read(environment: [String: String], listHelpers: Bool) async -> RegistrySnapshot {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let directory = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.docker"
        let path = directory + "/config.json"
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber, size.intValue <= 1_048_576,
                  let data = FileManager.default.contents(atPath: path),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .init(entries: [], incomplete: true)
            }
            json = config
        }
        let helpers = json["credHelpers"] as? [String: String] ?? [:]
        let auths = json["auths"] as? [String: [String: Any]] ?? [:]
        var defaultHelper = json["credsStore"] as? String ?? ""
        // Docker discovers its platform helper only if the file has no auth configuration.
        if defaultHelper.isEmpty, auths.isEmpty, helpers.isEmpty,
           helper("osxkeychain", environment: environment) != nil {
            defaultHelper = "osxkeychain"
        }
        let inline = auths.compactMap { key, value -> RegistryEntry? in
            guard let registry = entry(key), (helpers[registry.argument] ?? defaultHelper).isEmpty,
                  ["auth", "identitytoken", "registrytoken"].contains(where: {
                      guard let credential = value[$0] as? String else { return false }
                      return !credential.isEmpty
                  }) else { return nil }
            return registry
        }
        let stores = Set(helpers.values).union([defaultHelper]).subtracting([""])
        var entries = Set(inline)
        var incomplete = !listHelpers && !stores.isEmpty
        if listHelpers {
            for store in stores.sorted() {
                guard !Task.isCancelled, let executable = helper(store, environment: environment),
                      let data = try? await CLI.captured(executable: executable, ["list"], environment: environment, timeout: 3),
                      data.count <= 1_048_576,
                      let servers = try? JSONDecoder().decode([String: String].self, from: data) else {
                    incomplete = true
                    continue
                }
                for server in servers.keys {
                    if let registry = entry(server), (helpers[registry.argument] ?? defaultHelper) == store {
                        entries.insert(registry)
                    }
                }
            }
        }
        return .init(entries: entries.sorted { $0.name < $1.name }, incomplete: incomplete)
    }

    private static func helper(_ suffix: String, environment: [String: String]) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !suffix.isEmpty, suffix.count <= 64, suffix.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let executable = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { $0 + "/docker-credential-" + suffix }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return executable.map { URL(fileURLWithPath: $0) }
    }

    static func entry(_ key: String) -> RegistryEntry? {
        if ["https://index.docker.io/v1/", "https://index.docker.io/v1", "index.docker.io", "docker.io"].contains(key) {
            return .init(name: "Docker Hub", argument: "https://index.docker.io/v1/")
        }
        // Limit display and CLI arguments to registry authorities, never arbitrary config text.
        guard key.count <= 253, !key.hasPrefix("-"), !key.isEmpty,
              key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              key.contains(".") || key.contains(":") || key == "localhost" else { return nil }
        return .init(name: key, argument: key)
    }
}

struct RegistrySettings: View {
    let docker: String?
    let demo: Bool
    @State private var snapshot = RegistrySnapshot(entries: [], incomplete: true)
    @State private var selected: RegistryEntry?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        Section {
            if snapshot.entries.isEmpty {
                Text("No stored registry sign-ins found.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.entries, id: \.self) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Button("Sign Out…") { selected = entry }.disabled(busy || docker == nil || demo)
                }
            }
            if snapshot.incomplete {
                Text("Credential helper sign-ins may not be shown.").foregroundStyle(.secondary)
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            Button("Refresh Registries") { Task { await reload(listHelpers: true) } }.disabled(busy)
        } header: {
            Text("Signed-in registries")
        } footer: {
            Text("Sign in below or with docker login in Terminal. Sign out removes credentials from the Docker CLI configuration used by Noodle.")
        }
        .task { await reload(listHelpers: false) }
        .confirmationDialog("Sign out of \(selected?.name ?? "this registry")?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible, presenting: selected) { entry in
            Button("Sign Out", role: .destructive) { Task { await signOut(entry) } }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: { _ in
            Text("Docker CLI commands will need a new sign-in to access this registry.")
        }
    }

    private func reload(listHelpers: Bool) async {
        guard !busy else { return }
        if demo { snapshot = .init(entries: [], incomplete: false); return }
        busy = true
        let environment = ProcessInfo.processInfo.environment
        snapshot = await Task.detached { await RegistrySnapshot.read(environment: environment, listHelpers: listHelpers) }.value
        busy = false
    }

    private func signOut(_ entry: RegistryEntry) async {
        guard !busy, !demo, let docker else { return }
        busy = true
        selected = nil
        let arguments = entry.name == "Docker Hub" ? ["logout"] : ["logout", entry.argument]
        let result = await DockerSettingsCommands.run(docker, arguments)
        notice = result.code == 0 ? "Signed out of \(entry.name)." : "Could not sign out. Try docker logout in Terminal."
        busy = false
        await reload(listHelpers: true)
    }
}
