import Foundation
import NoodleCore

/// Canned daemon for `--demo`. Actions mutate local state and emit events, so the UI is explorable
/// without a daemon. Compiled into release builds too, because it is tiny and `--demo` is a user-facing flag.
actor DemoDocker: DockerService {
    enum Mode: Sendable { case normal, empty, down }
    private let mode: Mode
    private var items: [ContainerSummary]
    private var imageItems: [ImageSummary]
    private var volumeItems: [VolumeSummary]
    private var networkItems: [NetworkSummary]
    private var subscribers: [UUID: AsyncThrowingStream<DockerEvent, Error>.Continuation] = [:]

    init(mode: Mode) {
        self.mode = mode
        let now = Int(Date().timeIntervalSince1970)
        func c(_ id: String, _ name: String, _ image: String, _ state: String, _ status: String, age: Int,
               project: String? = nil, service: String? = nil, ports: [(Int, Int)] = []) -> ContainerSummary {
            var labels: [String: String] = [:]
            if let project {
                labels["com.docker.compose.project"] = project
                if !project.hasPrefix("noodle-app-") {
                    labels["com.docker.compose.project.working_dir"] = "/Users/demo/Code/\(project)"
                    labels["com.docker.compose.project.config_files"] = "/Users/demo/Code/\(project)/compose.yaml"
                }
            }
            if let service { labels["com.docker.compose.service"] = service }
            return ContainerSummary(id: id + String(repeating: "a1b2c3", count: 9), names: ["/" + name], image: image, state: state, status: status,
                                    created: now - age, ports: ports.map { PortMapping(ip: "0.0.0.0", privatePort: $0.1, publicPort: $0.0, type: "tcp") }, labels: labels)
        }
        items = mode == .normal ? [
            c("3f1e9c", "shop-web-1", "shop/web:latest", "running", "Up 2 hours", age: 7_400, project: "shop", service: "web", ports: [(3000, 3000)]),
            c("77ab02", "shop-api-1", "shop/api:latest", "running", "Up 2 hours", age: 7_400, project: "shop", service: "api", ports: [(8080, 8080)]),
            c("9d4410", "shop-db-1", "postgres:17-alpine", "running", "Up 2 hours (healthy)", age: 7_450, project: "shop", service: "db", ports: [(5432, 5432)]),
            c("c1c1d2", "shop-redis-1", "redis:7-alpine", "running", "Up 2 hours", age: 7_450, project: "shop", service: "redis"),
            DemoFlags.healthy
                ? c("a41f07", "shop-worker-1", "shop/worker:latest", "running", "Up 2 hours", age: 7_400, project: "shop", service: "worker")
                : c("a41f07", "shop-worker-1", "shop/worker:latest", "exited", "Exited (1) 4 minutes ago", age: 7_400, project: "shop", service: "worker"),
            c("48e0b7", "blog-ghost-1", "ghost:5-alpine", "exited", "Exited (0) 3 days ago", age: 260_000, project: "blog", service: "ghost", ports: [(2368, 2368)]),
            c("5a91ce", "blog-mysql-1", "mysql:8.4", "exited", "Exited (0) 3 days ago", age: 260_000, project: "blog", service: "mysql"),
            c("e2d7f8", "minio", "minio/minio:latest", "running", "Up 41 minutes", age: 2_500, ports: [(9000, 9000), (9001, 9001)]),
            c("d7c2e1", "noodle-app-open-webui-app-1", "ghcr.io/open-webui/open-webui:v0.13.4", "running", "Up 3 hours", age: 11_000,
              project: "noodle-app-open-webui", service: "app", ports: [(3000, 8080)]),
            c("b09a41", "scratch-alpine", "alpine:3.22", "exited", "Exited (0) 5 minutes ago", age: 900),
        ] : []
        imageItems = mode == .normal ? [
            ImageSummary(id: "sha256:1a2b3c4d5e6f", repoTags: ["shop/web:latest"], size: 214_000_000, created: now - 9_000, containers: 1),
            ImageSummary(id: "sha256:2b3c4d5e6f70", repoTags: ["shop/api:latest"], size: 98_000_000, created: now - 9_100, containers: 1),
            ImageSummary(id: "sha256:3c4d5e6f7081", repoTags: ["postgres:17-alpine"], size: 278_000_000, created: now - 1_200_000, containers: 1),
            ImageSummary(id: "sha256:4d5e6f708192", repoTags: ["redis:7-alpine"], size: 41_000_000, created: now - 2_000_000, containers: 1),
            ImageSummary(id: "sha256:5e6f708192a3", repoTags: ["ghost:5-alpine"], size: 480_000_000, created: now - 3_400_000, containers: 1),
            ImageSummary(id: "sha256:6f708192a3b4", repoTags: ["mysql:8.4"], size: 590_000_000, created: now - 3_000_000, containers: 1),
            ImageSummary(id: "sha256:708192a3b4c5", repoTags: ["minio/minio:latest"], size: 188_000_000, created: now - 600_000, containers: 1),
            ImageSummary(id: "sha256:8192a3b4c5d6", repoTags: ["alpine:3.22"], size: 8_400_000, created: now - 4_000_000, containers: 1),
            ImageSummary(id: "sha256:92a3b4c5d6e7", repoTags: [], size: 312_000_000, created: now - 5_000_000, containers: 0),
        ] : []
        volumeItems = mode == .normal ? [
            VolumeSummary(name: "shop_pgdata", mountpoint: "/var/lib/noodle/volumes/shop_pgdata"),
            VolumeSummary(name: "shop_redis", mountpoint: "/var/lib/noodle/volumes/shop_redis"),
            VolumeSummary(name: "blog_mysql", mountpoint: "/var/lib/noodle/volumes/blog_mysql"),
            VolumeSummary(name: "minio-data", mountpoint: "/var/lib/noodle/volumes/minio-data"),
        ] : []
        networkItems = [
            NetworkSummary(id: "n1", name: "bridge", driver: "bridge", subnet: "172.17.0.0/16", attached: mode == .normal ? 2 : 0),
            NetworkSummary(id: "n2", name: "host", driver: "host"),
            NetworkSummary(id: "n3", name: "none", driver: "null"),
        ] + (mode == .normal ? [
            NetworkSummary(id: "n4", name: "shop_default", driver: "bridge", subnet: "172.18.0.0/16", attached: 4),
            NetworkSummary(id: "n5", name: "blog_default", driver: "bridge", subnet: "172.19.0.0/16", attached: 0),
        ] : [])
    }

    private func emit(_ type: String, _ action: String, _ id: String) {
        let json = #"{"Type":"\#(type)","Action":"\#(action)","Actor":{"ID":"\#(id)"}}"#
        if let e = try? JSONDecoder().decode(DockerEvent.self, from: Data(json.utf8)) {
            for c in subscribers.values { c.yield(e) }
        }
    }
    func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
    func addSubscriber(_ id: UUID, _ c: AsyncThrowingStream<DockerEvent, Error>.Continuation) { subscribers[id] = c }

    func ping() async throws {
        if mode == .down { throw TransportError.unreachable("No such file or directory") }
    }
    func info() async throws -> DaemonInfo {
        DaemonInfo(name: "noodle", ncpu: 4, memTotal: 4 << 30, kernelVersion: "6.12.8", operatingSystem: "Noodle Linux", serverVersion: "27.0",
                   architecture: "aarch64", containersRunning: items.filter(\.isRunning).count)
    }
    func containers() async throws -> [ContainerSummary] { items }
    func localNames() async throws -> LocalNameTable {
        let hosts = ["shop-web-1": "web.localhost", "shop-api-1": "api.localhost", "minio": "minio.localhost",
                     "noodle-app-open-webui-app-1": "open-webui.localhost"]
        return LocalNameTable(entries: items.filter { $0.state == "running" }.compactMap { c in
            hosts[c.name].map { .init(host: $0, containerID: String(c.id.prefix(12))) }
        })
    }
    func modelConnection() async throws -> ModelRunnerConnection {
        .init(host: "http://host.docker.internal:11346/model-runner/demo", proxy: "http://127.0.0.1:11346")
    }
    func inspect(_ id: String) async throws -> ContainerDetails {
        guard let c = items.first(where: { $0.id == id }) else { throw HTTPFailure(status: 404, message: "No such container") }
        // Exit code and stop time follow the status text, so the demo agrees with its own list.
        let exitCode = c.status.firstIndex(of: "(").flatMap { Int(c.status[c.status.index(after: $0)...].prefix { $0.isNumber }) } ?? 0
        let finished = Date().addingTimeInterval(c.name == "shop-worker-1" ? -240 : -300)
        let json = """
        {"Id":"\(c.id)","Name":"/\(c.name)","Created":"2026-11-04T08:12:00Z",
         "State":{"Status":"\(c.state)","Running":\(c.isRunning),"Pid":\(c.isRunning ? 4121 : 0),"ExitCode":\(c.isRunning ? 0 : exitCode),"StartedAt":"2026-11-04T08:12:03Z","FinishedAt":"\(ISO8601DateFormatter().string(from: finished))"},
         "Config":{"Image":"\(c.image)","Cmd":["serve","--port","8080"],"Entrypoint":["/app/entrypoint.sh"],"Env":["NODE_ENV=production","DATABASE_URL=postgres://db:5432/shop","PORT=8080"],"Tty":false,"WorkingDir":"/app","User":"node"},
         "Mounts":[{"Type":"volume","Name":"shop_pgdata","Source":"/var/lib/noodle/volumes/shop_pgdata","Destination":"/var/lib/postgresql/data","RW":true},
                   {"Type":"bind","Source":"/Users/demo/Code/shop","Destination":"/app","RW":true}],
         "NetworkSettings":{"Networks":{"\(c.project.map { $0 + "_default" } ?? "bridge")":{"IPAddress":"172.18.0.\(2 + abs(c.id.hashValue) % 20)","Gateway":"172.18.0.1","MacAddress":"02:42:ac:12:00:02"}}},
         "HostConfig":{"Memory":0,"NanoCpus":0}}
        """
        return try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
    }
    func images() async throws -> [ImageSummary] { imageItems }
    func volumes() async throws -> [VolumeSummary] { volumeItems }
    func networks() async throws -> [NetworkSummary] { networkItems }

    private func setState(_ id: String, _ state: String, _ status: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state; items[i].status = status
    }
    func start(_ id: String) async throws {
        try await Task.sleep(for: .milliseconds(250))
        setState(id, "running", "Up Less than a second"); emit("container", "start", id)
    }
    func stop(_ id: String) async throws {
        try await Task.sleep(for: .milliseconds(350))
        setState(id, "exited", "Exited (0) Less than a second ago"); emit("container", "die", id)
    }
    func restart(_ id: String) async throws {
        try await Task.sleep(for: .milliseconds(450))
        setState(id, "running", "Up Less than a second"); emit("container", "restart", id)
    }
    func removeContainer(_ id: String) async throws { items.removeAll { $0.id == id }; emit("container", "destroy", id) }
    func removeImage(_ id: String) async throws { imageItems.removeAll { $0.id == id }; emit("image", "delete", id) }
    func removeVolume(_ name: String) async throws { volumeItems.removeAll { $0.name == name }; emit("volume", "destroy", name) }
    func removeNetwork(_ id: String) async throws { networkItems.removeAll { $0.id == id }; emit("network", "destroy", id) }

    func exec(_ id: String, argv: [String], timeout: Double) async throws -> DockerAPI.ExecResult {
        try await Task.sleep(for: .milliseconds(180))
        let line = argv.count >= 3 && argv[0] == "sh" ? argv[2] : argv.joined(separator: " ")
        if line.hasPrefix("echo ") { return .init(output: String(line.dropFirst(5)) + "\n", exitCode: 0) }
        if line == "uname -a" { return .init(output: "Linux noodle 6.12.8 #1 SMP aarch64 GNU/Linux\n", exitCode: 0) }
        return .init(output: "demo: \(line)\n", exitCode: 0)
    }

    func archive(_ id: String, path: String) async throws -> Data {
        let name = (path as NSString).lastPathComponent
        let body = Data("# \(name)\nThis is demo content for \(path).\nworker_processes auto;\nlisten 8080;\n".utf8)
        var header = Data(count: 512)
        func put(_ s: String, at o: Int) { header.replaceSubrange(o..<o + s.utf8.count, with: Array(s.utf8)) }
        put(name, at: 0); put("0000644", at: 100); put(String(format: "%011o", body.count), at: 124); put("0", at: 156)
        var out = header + body
        out.append(Data(count: (512 - body.count % 512) % 512 + 1024))
        return out
    }

    func list(_ id: String, path: String) async throws -> [FileEntry] {
        let base = path.hasSuffix("/") ? path : path + "/"
        let names: [(String, Bool)] = base == "/"
            ? [("app", true), ("bin", true), ("etc", true), ("home", true), ("usr", true), ("var", true), ("entrypoint.sh", false)]
            : [("config", true), ("logs", true), ("package.json", false), ("server.js", false), ("nginx.conf", false), ("README.md", false)]
        return names.map { FileEntry(path: base + $0.0, name: $0.0, isDirectory: $0.1) }
    }
}
