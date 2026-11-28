import Foundation
import NoodleCore

let toolDiscovery = ToolDiscovery(env: env, paths: paths)

/// The docker CLI found on this Mac, else Noodle's downloaded copy. Nothing is downloaded here.
func discoveredDocker() -> String? { toolDiscovery.docker() }

private enum PluginState { case ready, deferred, missing, blocked }

/// Make one plugin usable through `docker` (nil while docker is still to be downloaded).
private func preparePlugin(_ name: String, docker: String?) -> PluginState {
    let fm = FileManager.default
    let pluginDir = dockerConfigDirectory.appendingPathComponent("cli-plugins", isDirectory: true)
    let destination = pluginDir.appendingPathComponent(name)
    // Directory enumeration includes dangling symlinks: those are user-owned too.
    let occupied = ((try? fm.contentsOfDirectory(atPath: pluginDir.path)) ?? []).contains(name)
    if occupied {
        if LazyToolPlugin.ownsStub(destination, name: name, paths: paths, receipt: setupReceipt()) { return .deferred }
        let works = docker.map { toolDiscovery.plugin(name, worksUnder: $0) } ?? toolDiscovery.compatible(destination.path, name: name)
        if works { out("\(name): \(destination.path)"); return .ready }
        err("warning: existing \(destination.path) is unavailable or incompatible; preserved. Move it aside and run `noodle setup` to discover another installation.")
        return .blocked
    }
    // Always prepare Noodle's environment when we own the config slot, even if Desktop provides Model.
    if LazyToolPlugin.retainsStub(name) { return .deferred }
    if let docker, toolDiscovery.plugin(name, worksUnder: docker) { out("\(name): provided by \(docker)"); return .ready }
    let found = toolDiscovery.candidates(name, includeManaged: true).filter { $0 != destination.path }
    for candidate in found where toolDiscovery.compatible(candidate, name: name) {
        do {
            try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: destination, withDestinationURL: URL(fileURLWithPath: candidate))
            do { try setupRecordLink(destination, target: candidate) }
            catch { try? fm.removeItem(at: destination); throw error }
        } catch {
            err("warning: cannot link \(name): \(error.localizedDescription)")
            return .missing
        }
        // The link only counts if the docker CLI that will run it accepts it.
        if let docker, !toolDiscovery.plugin(name, worksUnder: docker) {
            try? fm.removeItem(at: destination)
            continue
        }
        out("\(name): linked \(candidate)")
        return .ready
    }
    return .missing
}

/// Setup fetches only the Docker CLI. Missing plugins get stubs after the CLI is retained.
func setupClients(prefetch: Bool) -> Set<String> {
    var toDownload = Set<String>()
    var deferredPlugins = Set<String>()
    var missing: [String] = []
    let docker = discoveredDocker()
    if let found = docker { out("docker: using \(found)") }
    else { missing.append("docker"); toDownload.insert("docker") }
    for name in Tools.pluginNames {
        switch preparePlugin(name, docker: docker) {
        case .ready: break
        case .blocked: missing.append(name)
        case .deferred, .missing:
            if prefetch { toDownload.insert(name) } else { deferredPlugins.insert(name) }
        }
    }
    if !toDownload.isEmpty {
        toolsInstall(names: toDownload)
        missing.removeAll { toDownload.contains($0) }
    }
    if !missing.isEmpty {
        out("Missing client tools: \(missing.joined(separator: ", ")). To download the pinned clients, run `noodle setup --tools`.")
    }
    // kubectl: only when none is on PATH, linked into ~/.local/bin like docker (never over a foreign file).
    if let found = which("kubectl") { out("kubectl: using \(found)") }
    else { toolsInstall(names: ["kubectl"]) }
    out("Build local Dockerfiles with `docker --context noodle build .` or `docker --context noodle buildx build .`.")
    if let builder = env["BUILDX_BUILDER"], !builder.isEmpty {
        out("BUILDX_BUILDER=\(builder) overrides the context builder; unset it to use Noodle's native builder.")
    }
    let current = dockerConfigDirectory.appendingPathComponent("buildx/current")
    if let data = try? Data(contentsOf: current),
       let selection = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       selection["Global"] as? Bool == true {
        out("Buildx has a global builder selection that overrides the context builder. Use `docker --context noodle buildx build --builder noodle .` to select Noodle explicitly.")
    }
    return deferredPlugins
}
