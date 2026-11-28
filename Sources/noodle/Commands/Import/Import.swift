import Foundation
import NoodleCore

// noodle import <source>: copy images, volumes (with ownership) and stopped containers from another
// Docker engine into Noodle. On demand: nothing runs until the command does.

private let importUsage = """
usage: noodle import <source> [--list] [--images] [--volumes] [--containers] [--all]
                     [--only name[,name...]] [--on-conflict skip|overwrite|rename] [--retries N] [--dry-run] [--json]
  <source>  a Docker context name (orbstack, desktop-linux, ...), "default", "podman" (the running Podman machine), or a unix:///path/to/docker.sock
  Without a kind, --all or --only, the source inventory is listed and nothing is copied.
"""

private struct Options {
    var source = ""
    var kinds: Set<String> = []
    var only: [String] = []
    var policy = ImportConflictPolicy.skip
    var retries = 3
    var dryRun = false
    var list = false
    var json = false
}

private func parse(_ args: [String]) throws -> Options {
    var o = Options(), i = 0
    func value() throws -> String { i += 1; guard i < args.count, !args[i].hasPrefix("-") else { throw ImportError.usage(importUsage) }; return args[i] }
    while i < args.count {
        switch args[i] {
        case "--list": o.list = true
        case "--dry-run": o.dryRun = true
        case "--json": o.json = true
        case "--images": o.kinds.insert("images")
        case "--volumes": o.kinds.insert("volumes")
        case "--containers": o.kinds.insert("containers")
        case "--all": o.kinds = ["images", "volumes", "containers"]
        case "--only": o.only += try value().split(separator: ",").map(String.init)
        case "--on-conflict":
            guard let p = ImportConflictPolicy(rawValue: try value()) else { throw ImportError.usage("--on-conflict takes skip, overwrite or rename") }
            o.policy = p
        case "--retries":
            guard let n = Int(try value()), n > 0 else { throw ImportError.usage("--retries takes a positive integer") }
            o.retries = n
        case let a where a.hasPrefix("-"): throw ImportError.usage("unknown flag \(a)\n" + importUsage)
        default:
            guard o.source.isEmpty else { throw ImportError.usage(importUsage) }
            o.source = args[i]
        }
        i += 1
    }
    guard !o.source.isEmpty else { throw ImportError.usage(importUsage) }
    if !o.only.isEmpty && o.kinds.isEmpty { o.kinds = ["images", "volumes", "containers"] }
    if o.kinds.isEmpty { o.list = true }
    return o
}

private func resolveSource(_ s: String, dockerConfig: String, env: [String: String], cancellation: ImportCancellation) throws -> String {
    if s.hasPrefix("unix://") || s.hasPrefix("/") { return try ImportNaming.socketPath(host: s) }
    if s == "default" { return try ImportNaming.socketPath(host: env["DOCKER_HOST"] ?? "unix:///var/run/docker.sock") }
    let meta = URL(fileURLWithPath: dockerConfig).appendingPathComponent("contexts/meta")
    var names: [String] = []
    for dir in (try? FileManager.default.contentsOfDirectory(atPath: meta.path)) ?? [] {
        if let data = try? Data(contentsOf: meta.appendingPathComponent(dir).appendingPathComponent("meta.json")),
           let c = ImportNaming.contextHost(metaJSON: data) {
            if c.name == s { return try ImportNaming.socketPath(host: c.host) }
            names.append(c.name)
        }
    }
    if s == "podman" {
        guard let path = podmanSocket(env: env, cancellation: cancellation) else {
            throw ImportError.fatal("no Podman machine socket found. Start it with `podman machine start`, or pass unix:///path/to/podman.sock.")
        }
        return path
    }
    // Naming `podman` as a source is always valid, so the hint lists it without probing for a machine.
    let known = names.sorted() + ["default", "podman"]
    throw ImportError.fatal("no Docker context named \(s) under \(dockerConfig)/contexts/meta. Sources: \(known.joined(separator: ", ")). Or pass unix:///path/to/docker.sock.")
}

private func wanted(_ o: Options, _ names: [String]) -> Bool {
    o.only.isEmpty || names.contains { n in o.only.contains { $0 == n || (n.hasPrefix("sha256:") && n.dropFirst(7).hasPrefix($0)) } }
}

private func mib(_ n: Int) -> String { String(format: "%.1f MiB", Double(n) / 1_048_576) }

func runImport(_ args: [String], destSocket: String, dockerConfig: String, tmpRoot: URL, env: [String: String]) -> Int32 {
    let cancellation = ImportCancellation()
    let signals = [SIGINT, SIGTERM, SIGHUP].map { number in
        let previous = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { cancellation.cancel() }
        source.resume()
        return (number, previous, source)
    }
    defer { for (number, previous, source) in signals { source.cancel(); signal(number, previous) } }
    do {
        let o = try parse(args)
        let sourcePath = try resolveSource(o.source, dockerConfig: dockerConfig, env: env, cancellation: cancellation)
        guard URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath() != URL(fileURLWithPath: destSocket).resolvingSymlinksInPath() else {
            throw ImportError.fatal("source and destination are the same engine")
        }
        let src = EngineEndpoint(name: "source", socketPath: sourcePath, cancellation: cancellation)
        let catalog = NoodlePaths.resolve(environment: env).imagesFile
        let dst = EngineEndpoint(name: "noodle", socketPath: destSocket, cancellation: cancellation, imageCatalog: catalog)
        guard (try? src.call("GET", "/_ping").status) == 200 else {
            throw ImportError.fatal(ImportPlan.sourceNotRunning(source: o.source, socketPath: sourcePath,
                                                                socketExists: FileManager.default.fileExists(atPath: sourcePath)))
        }
        guard (try? dst.call("GET", "/_ping").status) == 200 else { throw ImportError.engineDown("Noodle is not running. Start it with `noodle start`.") }
        let images = try src.images(), volumes = try src.volumes(), containers = try src.containers()
        let stopped = containers.filter { ["exited", "created"].contains($0["State"] as? String ?? "") }
        if o.list && o.json {
            out(jsonLine(importInventoryJSON(source: o.source, images: images, volumes: volumes, stopped: stopped)))
            return 0
        }
        if o.list {
            importList("images (\(images.filter { !$0.tags.isEmpty }.count) tagged, \(images.filter { $0.tags.isEmpty && !$0.refs.isEmpty }.count) digest-pinned, \(images.filter { $0.refs.isEmpty }.count) unreferenced and never copied)")
            for i in images where !i.refs.isEmpty { importList("  \(i.refs.joined(separator: ", "))  \(mib(i.size))") }
            importList("volumes (\(volumes.count))")
            for v in volumes { importList("  \(v["Name"] as? String ?? "?")  driver=\(v["Driver"] as? String ?? "?")") }
            importList("stopped containers (\(stopped.count) of \(containers.count) total; running ones are not copied)")
            for c in stopped { importList("  \((c["Names"] as? [String])?.first?.dropFirst() ?? "?")  image=\(c["Image"] as? String ?? "?")") }
            importLog("Choose with --images, --volumes, --containers, --all or --only NAME. Add --dry-run to preview.")
            return 0
        }
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let tmp = tmpRoot.appendingPathComponent("import-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var done = 0, skipped = 0, failed = 0
        var results: [[String: Any]] = []
        func step(_ kind: String, _ name: String, _ work: () throws -> String) throws {
            try cancellation.check()
            do {
                let r = try work()
                importLog("\(kind) \(name): \(r)")
                let wasSkipped = r.hasPrefix("skipped") || r.hasPrefix("already")
                if wasSkipped { skipped += 1 } else { done += 1 }
                results.append(["kind": kind, "name": name, "status": wasSkipped ? "skipped" : "copied", "detail": r])
            } catch {
                if cancellation.isCancelled { throw error }
                importLog("\(kind) \(name): FAILED \(error)"); failed += 1
                results.append(["kind": kind, "name": name, "status": "failed", "detail": "\(error)"])
            }
        }

        let ctx = ImportContext(src: src, dst: dst, tmp: tmp, options: (o.policy, o.retries, o.dryRun))
        defer { do { try dst.cleanup { try ctx.cleanup() } } catch { importLog("cleanup: FAILED \(error)") } }
        if o.kinds.contains("images") {
            for i in images where !i.refs.isEmpty && wanted(o, i.refs + [i.id]) { try step("image", i.refs[0], { try ctx.importImage(i) }) }
        }
        if o.kinds.contains("volumes") {
            for v in volumes where wanted(o, [v["Name"] as? String ?? ""]) { try step("volume", v["Name"] as? String ?? "?", { try ctx.importVolume(v, images: images) }) }
        }
        if o.kinds.contains("containers") {
            for c in stopped {
                let name = String(((c["Names"] as? [String])?.first ?? "").dropFirst())
                if wanted(o, [name, c["Id"] as? String ?? ""]) { try step("container", name, { try ctx.importContainer(c) }) }
            }
        }
        try cancellation.check()
        try dst.cleanup { try ctx.cleanup() }
        importLog("done: \(done) copied, \(skipped) unchanged or skipped, \(failed) failed\(o.dryRun ? " (dry run)" : "")")
        if o.json {
            out(jsonLine(importResultJSON(source: o.source, dryRun: o.dryRun, results: results,
                                          copied: done, skipped: skipped, failed: failed)))
        }
        return failed == 0 ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data("noodle: import: \(error)\n".utf8))
        return cancellation.isCancelled ? 130 : exitCode(for: error)
    }
}

/// The inventory is the data of `import --list`, so it is the one import output that stays on stdout.
private func importList(_ s: String) { print(s) }

func importInventoryJSON(source: String, images: [ImageInfo], volumes: [JSON], stopped: [JSON]) -> [String: Any] {
    [
        "schemaVersion": 1, "source": source,
        "images": images.filter { !$0.refs.isEmpty }.map { ["refs": $0.refs, "size": $0.size] as [String: Any] },
        "volumes": volumes.map { ["name": $0["Name"] as? String ?? "", "driver": $0["Driver"] as? String ?? ""] },
        "stoppedContainers": stopped.map {
            ["name": String((($0["Names"] as? [String])?.first ?? "").dropFirst()), "image": $0["Image"] as? String ?? ""]
        },
    ]
}

func importResultJSON(source: String, dryRun: Bool, results: [[String: Any]], copied: Int, skipped: Int, failed: Int) -> [String: Any] {
    ["schemaVersion": 1, "source": source, "dryRun": dryRun, "items": results,
     "summary": ["copied": copied, "skipped": skipped, "failed": failed]]
}

/// Shutdown interrupts blocked transfers. Short control requests and cleanup finish before cancellation unwinds.
final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var protected = 0
    private var socket: Int32?
    var isCancelled: Bool { lock.withLock { cancelled } }
    var isProtected: Bool { lock.withLock { protected > 0 } }
    func check() throws {
        if lock.withLock({ cancelled && protected == 0 }) { throw CancellationError() }
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            if protected == 0, let socket { _ = shutdown(socket, SHUT_RDWR) }
        }
    }
    func attach(_ fd: Int32) throws {
        try lock.withLock {
            if cancelled && protected == 0 { throw CancellationError() }
            socket = fd
        }
    }
    func closeSocket(_ fd: Int32) { lock.withLock { if socket == fd { socket = nil }; _ = close(fd) } }
    func cleanup<T>(_ work: () throws -> T) rethrows -> T {
        lock.withLock { protected += 1 }
        defer { lock.withLock { protected -= 1 } }
        return try work()
    }
    func finish<T>(_ work: () throws -> T) throws -> T {
        try lock.withLock {
            if cancelled && protected == 0 { throw CancellationError() }
            protected += 1
        }
        defer { lock.withLock { protected -= 1 } }
        return try work()
    }
}
