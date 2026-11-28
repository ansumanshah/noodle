import Foundation
import NoodleCore
import NoodleImages

// MARK: - Create

extension Engine {
    static let adjectives = ["admiring", "agitated", "amazing", "angry", "awesome", "blissful", "bold", "brave", "busy", "charming", "clever",
                             "cool", "dazzling", "determined", "eager", "elated", "epic", "focused", "frosty", "gifted", "happy", "hopeful",
                             "jolly", "keen", "kind", "laughing", "lucid", "modest", "nifty", "optimistic", "peaceful", "quirky", "relaxed",
                             "serene", "sharp", "silly", "stoic", "sweet", "tender", "upbeat", "vigilant", "wizardly", "zen"]
    static let surnames = ["archimedes", "bell", "boole", "curie", "darwin", "dijkstra", "euler", "faraday", "feynman", "galileo", "hopper",
                           "hypatia", "jemison", "kepler", "knuth", "lamport", "lovelace", "mayer", "noether", "newton", "pasteur",
                           "ritchie", "shannon", "thompson", "torvalds", "turing", "wescoff", "wilson", "yalow", "zhukovsky"]

    func randomName() -> String {
        for _ in 0..<50 {
            let n = "\(Self.adjectives.randomElement()!)_\(Self.surnames.randomElement()!)"
            if !containers.values.contains(where: { $0.name == n }) { return n }
        }
        return "container_" + IDs.random64().prefix(8)
    }

    func mapImageError(_ e: Error, _ name: String) -> Error {
        if case ImageError.notFound = e { return EngineError.notFound("No such image: \(name)") }
        if let ie = e as? ImageError { return EngineError.internalError(ie.description) }
        return e
    }

    public func createContainer(name rawName: String?, request: ContainerCreateRequest, platform: String? = nil) async throws -> (id: String, warnings: [String]) {
        var cfg = request.config
        var hc = request.hostConfig
        guard !cfg.Image.isEmpty else { throw EngineError.badRequest("no image specified") }
        let requestedPlatform: Platform?
        if let platform {
            let parts = platform.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), parts.allSatisfy({
                $0.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
            }), let parsed = Platform.parse(platform) else { throw EngineError.badRequest("invalid platform: \(platform)") }
            requestedPlatform = parsed
        } else { requestedPlatform = nil }
        let image: LocalImage
        do { image = try await imageStore.resolve(cfg.Image) } catch { throw mapImageError(error, cfg.Image) }
        guard imageRemovals == 0 else { throw EngineError.conflict("an image is being removed; try again once it finishes") }
        if let requestedPlatform {
            let actual = Platform.parse("\(image.os)/\(image.architecture)" + (image.variant.map { "/" + $0 } ?? ""))
            guard let actual, actual.os == requestedPlatform.os, actual.architecture == requestedPlatform.architecture,
                  requestedPlatform.variant == nil || requestedPlatform.variant == actual.variant else {
                throw EngineError.notFound("No such image: \(cfg.Image) for platform \(requestedPlatform)")
            }
        }

        var name = rawName ?? ""
        if name.hasPrefix("/") { name.removeFirst() }
        if name.isEmpty { name = randomName() }
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]+$", options: .regularExpression) != nil else {
            throw EngineError.invalid("Invalid container name (\(name)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        if let other = containers.values.first(where: { $0.name == name }) {
            throw EngineError.conflict("Container \"\(other.id)\" holds the name \"/\(name)\"; that name is already in use. Choose a different name, or release this one by renaming or removing its container.")
        }
        let policy = hc.RestartPolicy.Name
        guard ["", "no", "always", "unless-stopped", "on-failure"].contains(policy) else {
            throw EngineError.invalid("invalid restart policy '\(policy)'")
        }
        if hc.RestartPolicy.MaximumRetryCount < 0 { throw EngineError.invalid("maximum retry count cannot be negative") }
        if hc.RestartPolicy.MaximumRetryCount > 0 && policy != "on-failure" {
            throw EngineError.invalid("maximum retry count cannot be used with restart policy '\(policy)'")
        }
        if hc.AutoRemove && !(policy.isEmpty || policy == "no") {
            throw EngineError.invalid("can't create 'AutoRemove' container with restart policy")
        }

        _ = try LogRotationConfig.validate(hc.LogConfig)

        let id = IDs.random64()
        let ic = image.config.config
        // entrypoint / cmd resolution, the way docker run does it
        var ep = cfg.Entrypoint, cmd = cfg.Cmd
        if ep == [""] { ep = [] }
        if ep == nil && cmd == nil { ep = ic?.entrypoint; cmd = ic?.cmd }
        else if ep == nil { ep = ic?.entrypoint }
        else if cmd == nil { cmd = [] }
        if (ep ?? []).isEmpty && (cmd ?? []).isEmpty { throw EngineError.badRequest("No command specified") }
        cfg.Entrypoint = ep; cfg.Cmd = cmd
        cfg.Env = Self.mergeEnv(ic?.env ?? [], cfg.Env ?? [])
        cfg.Env = try injectingProxy(into: cfg.Env ?? [])
        if cfg.User.isEmpty { cfg.User = ic?.user ?? "" }
        if cfg.WorkingDir.isEmpty { cfg.WorkingDir = ic?.workingDir ?? "" }
        if cfg.Hostname.isEmpty { cfg.Hostname = String(id.prefix(12)) }
        cfg.Labels = (ic?.labels ?? [:]).merging(cfg.Labels ?? [:]) { $1 }
        if cfg.StopSignal == nil { cfg.StopSignal = ic?.stopSignal }
        if let ports = ic?.exposedPorts { cfg.ExposedPorts = (cfg.ExposedPorts ?? [:]).merging(ports.keys.filter { PortSpec.parse($0) != nil }.reduce(into: [:]) { $0[$1] = EmptyStruct() }) { a, _ in a } }
        try Self.validateHealthcheck(cfg.Healthcheck)
        if cfg.Healthcheck == nil, let h = ic?.healthcheck { var hcfg = HealthConfig(); hcfg.Test = h.test; hcfg.Interval = h.interval; hcfg.Timeout = h.timeout; hcfg.StartPeriod = h.startPeriod; hcfg.StartInterval = h.startInterval; hcfg.Retries = h.retries; cfg.Healthcheck = hcfg }
        try Self.validateHealthcheck(cfg.Healthcheck)
        let requestedImage = cfg.Image
        let imageVolumes = Array((ic?.volumes ?? [:]).keys)
        if cfg.Tty { cfg.AttachStdin = cfg.AttachStdin || cfg.OpenStdin }
        try Self.refuseUnsupported(hc)
        try checkCpusetRange(hc.CpusetCpus, hc.CpusetMems)
        if hc.ShmSize == 0 { hc.ShmSize = 67_108_864 }
        if hc.NetworkMode.isEmpty { hc.NetworkMode = "default" }

        // network
        let primary = try primaryNetworkName(hc.NetworkMode)
        var endpoints: [String: EndpointRecord] = [:]
        for (netRef, ep) in request.networking.EndpointsConfig ?? [:] {
            let nid = try networkID(netRef == "default" ? "bridge" : netRef)
            let n = networks[nid]!
            guard n.driver == "bridge" else { continue }
            var e = EndpointRecord(networkID: n.id, endpointID: IDs.random64(), aliases: ep.Aliases ?? [])
            e.staticIP = try requestedIP(ep, on: n)
            e.staticIP6 = try requestedIP6(ep, on: n)
            e.requestedMAC = try Self.requestedMAC(ep.MacAddress)
            e.links = ep.Links ?? []
            endpoints[n.name] = e
        }
        if let n = networks.values.first(where: { $0.name == primary }), n.driver == "bridge", endpoints[primary] == nil {
            endpoints[primary] = EndpointRecord(networkID: n.id, endpointID: IDs.random64())
        }

        try applyLinks(&hc, endpoints: &endpoints, primary: primary, name: name)

        if endpoints[primary]?.requestedMAC == nil {
            endpoints[primary]?.requestedMAC = try Self.requestedMAC(cfg.MacAddress)
        }

        var rec = ContainerRecord(id: id, name: name, created: Date(), image: requestedImage, imageID: image.id,
                                  config: cfg, hostConfig: hc)
        rec.endpoints = endpoints
        rec.primaryNetwork = primary
        let resolved = try resolveMounts(hc: hc, cfg: cfg, imageVolumes: imageVolumes, workload: Self.usesWorkload(rec))
        rec.mounts = resolved.points; rec.guestMounts = resolved.guest
        if Self.usesWorkload(rec) {
            guard image.architecture == "arm64" || image.architecture == "aarch64" else {
                throw EngineError.invalid("image \(cfg.Image) is \(image.architecture). Privileged and unconfined containers run in a separate VM that shares nothing with the Mac, so it has no Rosetta and runs arm64 images only")
            }
            try validateWorkloadBinds(rec)
            if rec.guestMounts.contains(where: { $0.kind == "docker" }) {
                throw EngineError.invalid("the Docker socket is not available in privileged or unconfined containers: they run in a separate VM that shares nothing with the Mac")
            }
            if rec.guestMounts.contains(where: { $0.kind == "agent" }) {
                throw EngineError.invalid("SSH agent forwarding is not available in privileged or unconfined containers: they run in a separate VM that shares nothing with the Mac")
            }
            if primary.hasPrefix("container:") {
                let target = try resolveContainerID(String(primary.dropFirst(10)))
                guard let t = containers[target], Self.usesWorkload(t) else {
                    throw EngineError.invalid("a privileged or unconfined container cannot share the network of an ordinary container: they run in different VMs")
                }
            }
        } else if primary.hasPrefix("container:"), let t = containers[try resolveContainerID(String(primary.dropFirst(10)))], Self.usesWorkload(t) {
            throw EngineError.invalid("an ordinary container cannot share the network of a privileged or unconfined container: they run in different VMs")
        }
        for vf in hc.VolumesFrom ?? [] {
            let source = try resolveContainerID(String(vf.split(separator: ":").first ?? ""))
            if let s = containers[source], Self.usesWorkload(s) != Self.usesWorkload(rec) {
                throw EngineError.invalid("--volumes-from \(s.name) is not available: privileged or unconfined containers and ordinary containers run in different VMs, and volumes are per VM")
            }
        }
        containers[id] = rec
        scheduleSave()
        emit("container", "create", id: id, attributes: containerAttributes(rec))
        return (id, [])
    }

}
