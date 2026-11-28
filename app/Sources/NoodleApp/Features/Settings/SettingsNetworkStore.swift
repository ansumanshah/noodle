import Foundation
import Observation

/// Settings reads happen on appearance or explicit refresh, never on a timer.
@MainActor
@Observable
final class SettingsNetworkStore {
    struct PublicLink: Decodable, Identifiable {
        let id: String
        let containerName: String
        let containerPort: Int
        let state: String
        let url: String?
        let detail: String?
    }

    struct FinderStatus: Decodable {
        var url: String?
        var mounted = false
        var mountpoint: String?
    }

    // The app depends on NoodleCore only. This DTO matches NoodleImages.ProxySettings's wire keys.
    struct ProxyConfiguration: Codable, Equatable {
        var mode = "system"
        var url: String?
        var exceptions: [String] = []
        var injectIntoContainers = false
    }

    var links: [PublicLink] = []
    var finder = FinderStatus()
    var proxy = ProxyConfiguration()
    var savedProxy = ProxyConfiguration()
    var busy = false
    var loaded = false
    var linksNote: String?
    var finderNote: String?
    var proxyNote: String?

    private func request(_ env: AppEnvironment, _ method: String, _ route: String,
                         body: Data? = nil, timeout: Double = 10) async throws -> Data {
        let reply = try await DockerSocket(path: env.paths.socket.path).request(
            method, route, body: body, contentType: body == nil ? nil : "application/json", timeout: timeout)
        guard (200..<300).contains(reply.status) else {
            // Proxy failures can contain credentials; never echo arbitrary server errors.
            throw HTTPFailure(status: reply.status, message: String(localized: "Settings request failed (HTTP \(reply.status))."))
        }
        return reply.body
    }

    func refresh(env: AppEnvironment) async {
        guard !busy, !env.demo else { return }
        busy = true
        defer { busy = false }
        do {
            links = try JSONDecoder().decode([PublicLink].self, from: await request(env, "GET", "/noodle/links"))
            linksNote = nil
        } catch { linksNote = "Could not load public links. \(error.localizedDescription)" }
        do {
            finder = try JSONDecoder().decode(FinderStatus.self, from: await request(env, "GET", "/noodle/finder"))
            finderNote = nil
        } catch { finderNote = "Could not load Finder state. \(error.localizedDescription)" }
        do {
            let value = try JSONDecoder().decode(ProxyConfiguration.self, from: await request(env, "GET", "/noodle/proxy"))
            proxy = value
            savedProxy = value
            loaded = true
            proxyNote = nil
        } catch { proxyNote = "Could not load proxy settings. \(error.localizedDescription)" }
    }

    func stopLink(_ id: String, env: AppEnvironment) async {
        guard !busy, !env.demo else { return }
        busy = true
        do {
            let data = try JSONEncoder().encode(["id": id])
            _ = try await request(env, "POST", "/noodle/links/stop", body: data)
            links = try JSONDecoder().decode([PublicLink].self, from: await request(env, "GET", "/noodle/links"))
            linksNote = nil
        } catch { linksNote = "Could not stop or refresh the link. \(error.localizedDescription)" }
        busy = false
    }

    func setFinder(enabled: Bool, env: AppEnvironment) async {
        guard !busy, !env.demo else { return }
        busy = true
        let result = await CLI.run(["finder", enabled ? "mount" : "unmount"], timeout: 30)
        finderNote = result.code == 0 ? nil : "Finder operation failed. Refresh to check its state. \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        do {
            finder = try JSONDecoder().decode(FinderStatus.self, from: await request(env, "GET", "/noodle/finder"))
        } catch { finderNote = "Could not refresh Finder state. \(error.localizedDescription)" }
        busy = false
    }

    func saveProxy(env: AppEnvironment) async {
        guard !busy, !env.demo, loaded else { return }
        busy = true
        defer { busy = false }
        do {
            let body = try JSONEncoder().encode(proxy)
            let value = try JSONDecoder().decode(ProxyConfiguration.self,
                from: await request(env, "POST", "/noodle/proxy", body: body))
            proxy = value
            savedProxy = value
            proxyNote = "Saved. Container injection applies to new containers only."
        } catch { proxyNote = "Could not save proxy settings. Check the HTTP URL and container injection settings. Credentials cannot be injected." }
    }

    func testProxy(env: AppEnvironment) async {
        guard !busy, !env.demo, loaded, proxy == savedProxy else { return }
        busy = true
        defer { busy = false }
        do {
            // Fetch a manifest through the daemon's registry client, without pulling image layers or starting a VM.
            _ = try await request(env, "GET", "/distribution/docker.io/library/alpine:latest/json", timeout: 20)
            proxyNote = "Registry connection succeeded using the saved settings."
        } catch { proxyNote = "Registry connection failed or timed out. Check the proxy, bypass rules and internet connection." }
    }
}
