import Foundation
import Testing
@testable import NoodleEngine
@testable import NoodleCore

func tempPaths() -> NoodlePaths {
    NoodlePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-eng-" + UUID().uuidString, isDirectory: true))
}

/// Registers a tiny local image (one tar layer) so containers can be created without a registry or VM.
func makeImage(_ engine: Engine, tag: String = "tiny:latest", cmd: [String]? = ["sh"], entrypoint: [String]? = nil,
               env: [String] = ["PATH=/bin", "A=1"], volumes: [String]? = nil) async throws -> LocalImage {
    let store = engine.imageStore
    let tarURL = store.blobs.tempURL()
    let w = try TarWriter(url: tarURL)
    try w.addFile("hello.txt", data: Data("hi".utf8))
    try w.finish()
    let digest = try Digest.sha256(file: tarURL)
    let size = (try FileManager.default.attributesOfItem(atPath: tarURL.path)[.size] as? NSNumber)!.int64Value
    try store.blobs.install(tarURL, as: digest)
    var cfg = ImageConfig()
    cfg.architecture = "arm64"; cfg.os = "linux"; cfg.created = ISO8601.string(Date())
    var rc = ImageConfig.RuntimeConfig()
    rc.cmd = cmd; rc.entrypoint = entrypoint; rc.env = env; rc.workingDir = "/work"
    if let volumes { rc.volumes = Dictionary(uniqueKeysWithValues: volumes.map { ($0, ImageConfig.EmptyObject()) }) }
    rc.exposedPorts = ["80/tcp": ImageConfig.EmptyObject()]
    cfg.config = rc
    return try await store.register(config: cfg, layers: [LayerRef(digest: digest, diffID: digest, mediaType: MediaType.ociLayerTar, size: size)], tags: [tag])
}

@Suite struct EngineModelTests {
    @Test func filtersParseBothForms() {
        let f = Filters.parse(#"{"status":["running","exited"],"label":["a=b","c"]}"#)
        #expect(f["status"] == ["running", "exited"])
        #expect(f.matchLabels(["a": "b", "c": "x"]))
        #expect(!f.matchLabels(["a": "b"]))
        let legacy = Filters.parse(#"{"dangling":{"true":true}}"#)
        #expect(legacy.bool("dangling") == true)
        #expect(Filters.parse(nil).values.isEmpty)
        #expect(Filters.parse("garbage").values.isEmpty)
        let neg = Filters.parse(#"{"label!":["x=1"]}"#)
        #expect(!neg.matchLabels(["x": "1"]))
        #expect(neg.matchLabels(["x": "2"]))
    }

    @Test func createRequestMatchesDockerBody() throws {
        let body = #"""
        {"Image":"alpine","Cmd":"echo hi","Env":["A=1"],"Tty":true,"ExposedPorts":{"80/tcp":{}},
         "HostConfig":{"Binds":["/Users/me/x:/x:ro"],"PortBindings":{"80/tcp":[{"HostIp":"","HostPort":"8080"}]},
                       "RestartPolicy":{"Name":"on-failure","MaximumRetryCount":3},"Memory":268435456,"NanoCpus":1500000000},
         "NetworkingConfig":{"EndpointsConfig":{"mynet":{"Aliases":["web"]}}}}
        """#
        let req = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(body.utf8))
        #expect(req.config.Image == "alpine")
        #expect(req.config.Cmd == ["echo hi"])          // string form becomes a single argv
        #expect(req.config.Tty)
        #expect(req.hostConfig.Binds == ["/Users/me/x:/x:ro"])
        #expect(req.hostConfig.PortBindings?["80/tcp"]??.first?.HostPort == "8080")
        #expect(req.hostConfig.RestartPolicy.Name == "on-failure")
        #expect(req.hostConfig.RestartPolicy.MaximumRetryCount == 3)
        #expect(req.hostConfig.Memory == 268435456)
        #expect(req.networking.EndpointsConfig?["mynet"]?.Aliases == ["web"])
        // null and missing fields are tolerated
        let sparse = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(#"{"Image":"x","Cmd":null,"HostConfig":null}"#.utf8))
        #expect(sparse.config.Cmd == nil)
        #expect(sparse.hostConfig.NetworkMode == "default")
        // encodes the Config fields at top level next to HostConfig
        let out = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(out["Image"] as? String == "alpine")
        #expect(out["HostConfig"] != nil)
    }

    @Test func ipamAllocatesAndReleases() throws {
        let net = try #require(IPv4Net(cidr: "172.18.0.0/16"))
        #expect(IPv4Net.string(net.gateway) == "172.18.0.1")
        var ipam = IPAM(net: net, gateway: nil)
        let a = try ipam.allocate(for: "a"), b = try ipam.allocate(for: "b")
        #expect(IPv4Net.string(a) == "172.18.0.2")
        #expect(IPv4Net.string(b) == "172.18.0.3")
        #expect(try ipam.allocate(for: "a") == a)                  // idempotent per container
        ipam.release(container: "a")
        let want = try #require(IPv4Net.parse("172.18.5.5"))
        #expect(try ipam.allocate(for: "c", preferred: want) == want)
        #expect(throws: EngineError.self) { try ipam.allocate(for: "d", preferred: want) }
        #expect(throws: EngineError.self) { try ipam.allocate(for: "d", preferred: net.gateway) }
        #expect(throws: EngineError.self) { try ipam.allocate(for: "d", preferred: IPv4Net.parse("10.0.0.5")!) }
        #expect(MAC.forIP(a) == "02:42:ac:12:00:02")
        #expect(IPv4Net(cidr: "10.0.0.0/8")!.overlaps(IPv4Net(cidr: "10.1.0.0/16")!))
        #expect(IPv4Net(cidr: "garbage") == nil)
    }

    @Test func ipamStaysInsideItsRange() throws {
        let net = try #require(IPv4Net(cidr: "10.9.0.0/24"))
        let range = try #require(IPv4Net(cidr: "10.9.0.8/30"))
        var ipam = IPAM(net: net, gateway: nil, range: range, reserved: [], label: "10.9.0.0/24")
        #expect(IPv4Net.string(try ipam.allocate(for: "a")) == "10.9.0.8")
        #expect(IPv4Net.string(try ipam.allocate(for: "b")) == "10.9.0.9")
        #expect(IPv4Net.string(try ipam.allocate(for: "c")) == "10.9.0.10")
        #expect(IPv4Net.string(try ipam.allocate(for: "d")) == "10.9.0.11")
        #expect(throws: EngineError.self) { try ipam.allocate(for: "e") }
        // A static address may sit outside the range as long as it is in the subnet.
        let outside = try #require(IPv4Net.parse("10.9.0.100"))
        #expect(try ipam.allocate(for: "f", preferred: outside) == outside)
    }

    @Test func ipamSkipsReservedAddresses() throws {
        let net = try #require(IPv4Net(cidr: "10.9.0.0/29"))
        let reserved = try #require(IPv4Net.parse("10.9.0.2"))
        var ipam = IPAM(net: net, gateway: nil, range: nil, reserved: [reserved], label: "10.9.0.0/29")
        #expect(IPv4Net.string(try ipam.allocate(for: "a")) == "10.9.0.3")
        #expect(throws: EngineError.self) { try ipam.allocate(for: "b", preferred: reserved) }
    }

    @Test func signalNames() throws {
        #expect(try Engine.signalNumber("SIGKILL") == 9)
        #expect(try Engine.signalNumber("term") == 15)
        #expect(try Engine.signalNumber("2") == 2)
        #expect(try Engine.signalNumber(nil) == 15)
        #expect(throws: EngineError.self) { try Engine.signalNumber("NOPE") }
    }

    @Test func envMergeAndChanges() {
        #expect(Engine.mergeEnv(["A=1", "B=2"], ["B=3", "C=4"]) == ["A=1", "B=3", "C=4"])
        var cfg = ContainerConfig()
        Engine.applyChanges(["CMD [\"nginx\",\"-g\",\"daemon off;\"]", "ENV FOO=bar BAZ=1", "EXPOSE 8080", "WORKDIR /srv", "LABEL a=b", "USER app", "ENTRYPOINT /run.sh"], to: &cfg)
        #expect(cfg.Cmd == ["nginx", "-g", "daemon off;"])
        #expect(cfg.Env == ["FOO=bar", "BAZ=1"])
        #expect(cfg.ExposedPorts?["8080/tcp"] != nil)
        #expect(cfg.WorkingDir == "/srv")
        #expect(cfg.Labels?["a"] == "b")
        #expect(cfg.User == "app")
        #expect(cfg.Entrypoint == ["/bin/sh", "-c", "/run.sh"])
    }

    @Test func humanDurations() {
        #expect(Engine.humanDuration(0.2) == "Less than a second")
        #expect(Engine.humanDuration(30) == "30 seconds")
        #expect(Engine.humanDuration(75) == "About a minute")
        #expect(Engine.humanDuration(3 * 3600) == "3 hours")
        #expect(Engine.humanDuration(3 * 86400) == "3 days")
    }

    @Test func tarStatParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-" + UUID().uuidString + ".tar")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try TarWriter(url: url)
        try w.addFile("dir/hello.txt", data: Data("hello".utf8), mode: 0o640, mtime: 1_700_000_000)
        try w.finish()
        let head = try Data(contentsOf: url).prefix(512)
        let st = try #require(Engine.pathStat(fromTarHeader: Data(head)))
        #expect(st.name == "hello.txt")
        #expect(st.size == 5)
        #expect(st.mode == 0o640)
    }
}

@Suite struct EngineLifecycleTests {
    @Test func dockerDefaultEndpointUsesBridge() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let request = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(#"{"Image":"tiny","HostConfig":{"NetworkMode":"default"},"NetworkingConfig":{"EndpointsConfig":{"default":{}}}}"#.utf8))
        let (id, _) = try await engine.createContainer(name: nil, request: request)
        #expect(try await engine.inspectContainer(id).NetworkSettings.Networks["bridge"] != nil)
        await engine.shutdown()
    }

    @Test func requestedMacIsMappedAndValidated() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let body = #"{"Image":"tiny","MacAddress":"02:42:AC:11:00:99","NetworkingConfig":{"EndpointsConfig":{"default":{}}}}"#
        let req = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(body.utf8))
        let id = try await engine.createContainer(name: nil, request: req).id
        let bridgeID = try await engine.networkID("bridge")
        let bridge = try #require(await engine.networks[bridgeID])
        let endpoint = try await engine.allocateEndpoint(containerID: id, on: bridge)
        #expect(endpoint.mac == "02:42:ac:11:00:99")
        #expect(try await engine.inspectContainer(id).NetworkSettings.MacAddress == endpoint.mac)
        let modernBody = #"{"Image":"tiny","NetworkingConfig":{"EndpointsConfig":{"default":{"MacAddress":"02:42:ac:11:00:98"}}}}"#
        let modernReq = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(modernBody.utf8))
        let modernID = try await engine.createContainer(name: nil, request: modernReq).id
        #expect(try await engine.allocateEndpoint(containerID: modernID, on: bridge).mac == "02:42:ac:11:00:98")
        #expect(throws: EngineError.self) { try Engine.requestedMAC("01:00:00:00:00:00") }
        #expect(throws: EngineError.self) { try Engine.requestedMAC("invalid") }
        await engine.shutdown()
    }

    @Test func createInspectListRenameRemove() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await engine.start()
        let img = try await makeImage(engine, cmd: ["sh"], volumes: ["/data"])

        var req = ContainerCreateRequest()
        req.config.Image = "tiny"
        req.config.Env = ["A=2", "B=3"]
        req.config.Labels = ["role": "web"]
        req.hostConfig.PortBindings = ["80/tcp": [PortBinding(HostIp: "", HostPort: "8080")]]
        let (id, _) = try await engine.createContainer(name: "web1", request: req)
        #expect(id.count == 64)

        let info = try await engine.inspectContainer("web1")
        #expect(info.Name == "/web1")
        #expect(info.Image == img.id)
        #expect(info.Path == "sh")
        #expect(info.Config.Image == "tiny")
        #expect(info.Config.Env == ["PATH=/bin", "A=2", "B=3"])      // image env merged, request wins
        #expect(info.Config.WorkingDir == "/work")
        #expect(info.Config.Hostname == String(id.prefix(12)))
        #expect(info.State.Status == "created")
        #expect(!info.State.Running)
        #expect(info.Mounts.count == 1)                              // anonymous volume from the image's VOLUME
        #expect(info.Mounts[0].Destination == "/data")
        #expect(info.Config.ExposedPorts?["80/tcp"] != nil)
        #expect(info.NetworkSettings.Networks["bridge"] != nil)

        // lookups by prefix, name and slash-name
        #expect(try await engine.inspectContainer(String(id.prefix(6))).Id == id)
        #expect(try await engine.inspectContainer("/web1").Id == id)
        await #expect(throws: EngineError.self) { try await engine.inspectContainer("nope") }

        // list + filters
        #expect(await engine.listContainers(all: false).isEmpty)
        let all = await engine.listContainers(all: true)
        #expect(all.count == 1)
        #expect(all[0].Names == ["/web1"]); #expect(all[0].State == "created"); #expect(all[0].Status == "Created")
        #expect(await engine.listContainers(all: true, filters: Filters(["label": ["role=web"]])).count == 1)
        #expect(await engine.listContainers(all: true, filters: Filters(["label": ["role=db"]])).count == 0)
        #expect(await engine.listContainers(all: true, filters: Filters(["name": ["web"]])).count == 1)
        #expect(await engine.listContainers(all: true, filters: Filters(["ancestor": ["tiny"]])).count == 1)
        #expect(await engine.listContainers(all: true, filters: Filters(["status": ["running"]])).count == 0)

        // duplicate name
        await #expect(throws: EngineError.self) { try await engine.createContainer(name: "web1", request: req) }
        // rename
        try await engine.renameContainer("web1", to: "web2")
        #expect(try await engine.inspectContainer(id).Name == "/web2")

        // stop on a created container is "not modified", kill on it is a conflict
        await #expect(throws: EngineError.self) { try await engine.stopContainer(id) }
        await #expect(throws: EngineError.self) { try await engine.killContainer(id) }

        // wait on a stopped container returns at once
        #expect(try await engine.waitContainer(id).StatusCode == 0)

        // removing never boots the VM when nothing is running
        try await engine.removeContainer(id, removeVolumes: true)
        #expect(await engine.listContainers(all: true).isEmpty)
        #expect(await engine.listVolumes().isEmpty)
        #expect(await engine.vmStatus().state == "stopped")
        await engine.shutdown()
    }

    @Test func entrypointRules() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await engine.start()
        _ = try await makeImage(engine, tag: "ep:1", cmd: ["--default"], entrypoint: ["/entry"])
        var r1 = ContainerCreateRequest(); r1.config.Image = "ep:1"
        let (a, _) = try await engine.createContainer(name: nil, request: r1)
        let ia = try await engine.inspectContainer(a)
        #expect(ia.Path == "/entry"); #expect(ia.Args == ["--default"])

        var r2 = r1; r2.config.Cmd = ["--custom"]                    // cmd override keeps the entrypoint
        let ib = try await engine.inspectContainer(try await engine.createContainer(name: nil, request: r2).id)
        #expect(ib.Args == ["--custom"])

        var r3 = r1; r3.config.Entrypoint = ["/other"]               // entrypoint override drops the image cmd
        let ic = try await engine.inspectContainer(try await engine.createContainer(name: nil, request: r3).id)
        #expect(ic.Path == "/other"); #expect(ic.Args.isEmpty)

        var missing = ContainerCreateRequest(); missing.config.Image = "ghost:1"
        await #expect(throws: EngineError.self) { try await engine.createContainer(name: nil, request: missing) }
        await engine.shutdown()
    }

    @Test func mountsAndBinds() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await engine.start()
        _ = try await makeImage(engine)
        let home = NSHomeDirectory()
        let dir = home + "/.noodle-test-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var req = ContainerCreateRequest(); req.config.Image = "tiny"
        req.hostConfig.Binds = ["\(dir):/host:ro", "named:/vol", "/anon"]
        req.hostConfig.Tmpfs = ["/scratch": "size=64m"]
        let (id, _) = try await engine.createContainer(name: nil, request: req)
        let m = try await engine.inspectContainer(id).Mounts
        #expect(m.count == 4)
        let bind = try #require(m.first { $0.Type == "bind" })
        #expect(bind.Destination == "/host"); #expect(!bind.RW); #expect(bind.Source.hasSuffix(dir.split(separator: "/").last!.description))
        #expect(FileManager.default.fileExists(atPath: dir))         // docker creates missing -v sources
        #expect(m.contains { $0.Type == "volume" && $0.Name == "named" && $0.Destination == "/vol" })
        #expect(m.contains { $0.Type == "tmpfs" && $0.Destination == "/scratch" })
        #expect(await engine.listVolumes().map(\.Name).contains("named"))

        // Created containers retain their mounted volumes even on forced removal.
        await #expect(throws: EngineError.self) { try await engine.removeVolume("named") }
        await #expect(throws: EngineError.self) { try await engine.removeVolume("named", force: true) }
        #expect(try await engine.inspectVolume("named").Name == "named")

        // Exact file shares are rejected rather than exposing their sibling files.
        let file = URL(fileURLWithPath: dir).appendingPathComponent("file")
        try Data().write(to: file)
        var bad = req; bad.hostConfig.Binds = ["\(file.path):/x"]
        await #expect(throws: EngineError.self) { try await engine.createContainer(name: nil, request: bad) }
        await engine.shutdown()
    }

    @Test func networksAndVolumes() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await engine.start()

        let builtin = await engine.listNetworks()
        #expect(Set(builtin.map(\.Name)) == ["bridge", "host", "none"])
        let bridge = try #require(builtin.first { $0.Name == "bridge" })
        #expect(bridge.IPAM.Config?.first?.Subnet == "172.18.0.0/16")
        #expect(bridge.IPAM.Config?.first?.Gateway == "172.18.0.1")
        await #expect(throws: EngineError.self) { try await engine.removeNetwork("bridge") }

        var n = NetworkCreateRequest(); n.Name = "backend"; n.Labels = ["env": "dev"]
        let (nid, _) = try await engine.createNetwork(n)
        let r = try await engine.inspectNetwork("backend")
        #expect(r.Id == nid)
        #expect(r.IPAM.Config?.first?.Subnet == "172.19.0.0/16")     // next free pool after the default bridge
        #expect(r.Labels["env"] == "dev")
        await #expect(throws: EngineError.self) { try await engine.createNetwork(n) }   // duplicate name
        var n2 = NetworkCreateRequest(); n2.Name = "second"; n2.IPAM.Config = [IPAMPool(Subnet: "10.9.0.0/24", Gateway: "10.9.0.1")]
        _ = try await engine.createNetwork(n2)
        #expect(try await engine.inspectNetwork("second").IPAM.Config?.first?.Subnet == "10.9.0.0/24")
        var overlap = NetworkCreateRequest(); overlap.Name = "x"; overlap.IPAM.Config = [IPAMPool(Subnet: "10.9.0.0/25")]
        await #expect(throws: EngineError.self) { try await engine.createNetwork(overlap) }
        #expect(await engine.listNetworks(filters: Filters(["name": ["back"]])).count == 1)

        // containers can be created on a user network without a VM; the endpoint is recorded, no IP until start
        _ = try await makeImage(engine)
        var req = ContainerCreateRequest(); req.config.Image = "tiny"; req.hostConfig.NetworkMode = "backend"
        let (cid, _) = try await engine.createContainer(name: "svc", request: req)
        let info = try await engine.inspectContainer(cid)
        #expect(info.NetworkSettings.Networks["backend"]?.NetworkID == nid)
        #expect(info.NetworkSettings.Networks["backend"]?.IPAddress == "")
        try await engine.removeContainer(cid)
        let pruned = await engine.pruneNetworks()
        #expect(Set(pruned.NetworksDeleted) == ["backend", "second"])

        // volumes
        var v = VolumeCreateRequest(); v.Name = "data"; v.Labels = ["k": "v"]
        let vol = try await engine.createVolume(v)
        #expect(vol.Name == "data"); #expect(vol.Mountpoint == "/var/lib/docker/volumes/data/_data")
        #expect(try await engine.createVolume(v).Name == "data")      // idempotent
        #expect(await engine.listVolumes(filters: Filters(["label": ["k=v"]])).count == 1)
        #expect(await engine.listVolumes(filters: Filters(["dangling": ["true"]])).count == 1)
        var bad = VolumeCreateRequest(); bad.Name = "bad name!"
        await #expect(throws: EngineError.self) { try await engine.createVolume(bad) }
        try await engine.removeVolume("data")
        await #expect(throws: EngineError.self) { try await engine.inspectVolume("data") }
        await engine.shutdown()
    }

    @Test func deferredVolumeRemovalSurvivesRecreationAndGuestFailure() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        var request = VolumeCreateRequest(); request.Name = "reused"
        let first = Engine(paths: paths)
        try await first.start()
        _ = try await first.createVolume(request)
        try await first.removeVolume("reused")
        _ = try await first.createVolume(request)
        await first.shutdown()

        let second = Engine(paths: paths)
        try await second.start()
        #expect(try await second.inspectVolume("reused").Name == "reused")
        await #expect(throws: (any Error).self) { try await second.removePendingGuestVolume("reused", second.main) }
        #expect(await second.pendingRemovals.volumes == ["reused"])
        await second.shutdown()
        let saved = try JSONDecoder.engine.decode(EngineState.self, from: Data(contentsOf: paths.stateFile))
        #expect(saved.volumes.map(\.name) == ["reused"])
        #expect(saved.pending?.volumes == ["reused"])
    }

    @Test func stateSurvivesRestart() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let first = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await first.start()
        _ = try await makeImage(first)
        var req = ContainerCreateRequest(); req.config.Image = "tiny"; req.hostConfig.RestartPolicy = RestartPolicy(Name: "no")
        let (id, _) = try await first.createContainer(name: "keeper", request: req)
        var n = NetworkCreateRequest(); n.Name = "persisted"
        _ = try await first.createNetwork(n)
        _ = try await first.createVolume({ var v = VolumeCreateRequest(); v.Name = "pv"; return v }())
        await first.shutdown()

        let second = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await second.start()
        #expect(try await second.inspectContainer("keeper").Id == id)
        #expect(try await second.inspectNetwork("persisted").Name == "persisted")
        #expect(try await second.inspectVolume("pv").Name == "pv")
        #expect(await second.listImages().count == 1)
        #expect(await second.listNetworks().count == 4)
        await second.shutdown()
    }

    @Test func imageOperations() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await engine.start()
        let img = try await makeImage(engine, tag: "app:1")
        try await engine.tagImage("app:1", repo: "registry.example.com/team/app", tag: "stable")
        let list = await engine.listImages()
        #expect(list.count == 1)
        #expect(Set(list[0].RepoTags) == ["app:1", "registry.example.com/team/app:stable"])
        let insp = try await engine.inspectImage("app:1")
        #expect(insp.Id == img.id)
        #expect(insp.Config.Cmd == ["sh"])
        #expect(insp.RootFS.Layers.count == 1)
        #expect(try await engine.inspectImage(String(img.id.dropFirst(7).prefix(12))).Id == img.id)
        await #expect(throws: EngineError.self) { try await engine.inspectImage("missing") }
        #expect(await engine.listImages(filters: Filters(["reference": ["registry.example.com/*"]])).count == 1)
        #expect(await engine.listImages(filters: Filters(["reference": ["other*"]])).count == 0)

        // save + remove + load round trip
        let tar = paths.tmpDir.appendingPathComponent("save.tar")
        try await engine.saveImages(["app:1"], to: tar)
        let del = try await engine.removeImage("app:1")
        #expect(del.contains { $0.Untagged == "app:1" })
        #expect(await engine.listImages().count == 1)                // still tagged under the registry name
        let del2 = try await engine.removeImage("registry.example.com/team/app:stable")
        #expect(del2.contains { $0.Deleted == img.id })
        #expect(await engine.listImages().isEmpty)
        let loaded = try await engine.loadImages(from: tar)
        #expect(loaded.count == 1); #expect(loaded[0].id == img.id); #expect(Set(loaded[0].repoTags) == ["app:1", "registry.example.com/team/app:stable"])
        #expect(try await engine.inspectImage("app:1").Id == img.id)
        // history shows the single layer
        #expect(try await engine.imageHistory("app:1").count >= 1)

        // images used by containers cannot be removed without force (once only one tag is left)
        _ = try await engine.removeImage("registry.example.com/team/app:stable")
        var req = ContainerCreateRequest(); req.config.Image = "app:1"
        let (cid, _) = try await engine.createContainer(name: nil, request: req)
        await #expect(throws: EngineError.self) { try await engine.removeImage("app:1") }
        try await engine.removeContainer(cid)
        _ = try await engine.removeImage("app:1")
        await engine.shutdown()
    }

    @Test func eventsAreDelivered() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        try await engine.start()
        _ = try await makeImage(engine)
        let stream = await engine.events(since: nil, filters: Filters(["type": ["container"]]))
        var req = ContainerCreateRequest(); req.config.Image = "tiny"
        let (id, _) = try await engine.createContainer(name: "ev", request: req)
        var got: [String] = []
        let reader = Task { () -> [String] in
            var out: [String] = []
            for await e in stream { out.append(e.Action); if e.Action == "destroy" { break } }
            return out
        }
        try await engine.removeContainer(id)
        got = await reader.value
        #expect(got.contains("destroy"))
        let past = await engine.events(since: 0)
        var count = 0
        for await _ in past { count += 1; if count >= 2 { break } }
        #expect(count >= 2)
        await engine.shutdown()
    }
}

@Suite struct IPv6PoolTests {
    @Test func addressesParseAndPrintInShortForm() throws {
        let a = try #require(IPv6Addr("FD6E:6F6F:646C:0001:0:0:0:2"))
        #expect(a.string == "fd6e:6f6f:646c:1::2")
        #expect(IPv6Addr("172.18.0.1") == nil)
        #expect(IPv6Addr("fe80::1%en0") == nil)
        #expect(IPv6Addr(hi: 0, lo: .max).next() == IPv6Addr(hi: 1, lo: 0))
    }

    @Test func subnetsMaskContainAndOverlap() throws {
        let n = try #require(IPv6Net(cidr: "fd00:1::5/64"))
        #expect(n.cidr == "fd00:1::/64")
        #expect(n.gateway.string == "fd00:1::1")
        #expect(n.contains(try #require(IPv6Addr("fd00:1::ffff"))))
        #expect(!n.contains(try #require(IPv6Addr("fd00:2::1"))))
        #expect(n.last.string == "fd00:1::ffff:ffff:ffff:ffff")
        let inner = try #require(IPv6Net(cidr: "fd00:1::/80"))
        #expect(n.overlaps(inner) && inner.overlaps(n))
        #expect(!n.overlaps(try #require(IPv6Net(cidr: "fd00:2::/64"))))
        #expect(IPv6Net(cidr: "10.0.0.0/8") == nil)
        #expect(IPv6Net(cidr: "fd00:zz::/64") == nil)
        #expect(try #require(IPv6Net(cidr: "fd00::/36")).last.string == "fd00:0:fff:ffff:ffff:ffff:ffff:ffff")
    }

    @Test func dynamicAddressesSkipGatewayAndReservedAndReuseAfterRelease() throws {
        let net = try #require(IPv6Net(cidr: "fd00:1::/64"))
        var pool = IPAM6(net: net, gateway: nil, reserved: [try #require(IPv6Addr("fd00:1::3"))])
        #expect(try pool.allocate(for: "a").string == "fd00:1::2")
        #expect(try pool.allocate(for: "a").string == "fd00:1::2")
        #expect(try pool.allocate(for: "b").string == "fd00:1::4")
        pool.release(container: "a")
        #expect(pool.leases.count == 1)
    }

    @Test func staticAddressRules() throws {
        let net = try #require(IPv6Net(cidr: "fd00:1::/64"))
        var pool = IPAM6(net: net, gateway: nil)
        let want = try #require(IPv6Addr("fd00:1::99"))
        #expect(try pool.allocate(for: "a", preferred: want) == want)
        #expect(throws: EngineError.self) { try pool.allocate(for: "b", preferred: want) }
        #expect(throws: EngineError.self) { try pool.allocate(for: "b", preferred: net.gateway) }
        #expect(throws: EngineError.self) { try pool.allocate(for: "b", preferred: IPv6Addr("fd00:2::1")) }
    }

    @Test func aSmallRangeRunsOut() throws {
        let net = try #require(IPv6Net(cidr: "fd00:1::/64"))
        let range = try #require(IPv6Net(cidr: "fd00:1::10/127", prefixes: 1...128))
        var pool = IPAM6(net: net, gateway: nil, range: range)
        #expect(try pool.allocate(for: "a").string == "fd00:1::10")
        #expect(try pool.allocate(for: "b").string == "fd00:1::11")
        #expect(throws: EngineError.self) { try pool.allocate(for: "c") }
    }

    @Test func publishPicksTheHostFamilyThenFallsBack() {
        var dual = EndpointRecord(networkID: "n", endpointID: "e"); dual.ip = "172.19.0.2"; dual.ip6 = "fd00::2"
        var only6 = EndpointRecord(networkID: "n", endpointID: "e"); only6.ip6 = "fd00::2"
        var only4 = EndpointRecord(networkID: "n", endpointID: "e"); only4.ip = "172.19.0.2"
        #expect(Engine.publishTarget(hostIP: "0.0.0.0", dual) == "172.19.0.2")
        #expect(Engine.publishTarget(hostIP: "::", dual) == "fd00::2")
        #expect(Engine.publishTarget(hostIP: "0.0.0.0", only6) == "fd00::2")
        #expect(Engine.publishTarget(hostIP: "::1", only4) == "172.19.0.2")
    }

    @Test func oldEndpointsAndNetworksStillDecode() throws {
        let old = #"{"networkID":"n","endpointID":"e","ip":"","mac":"","aliases":[],"links":[]}"#
        let e = try JSONDecoder().decode(EndpointRecord.self, from: Data(old.utf8))
        #expect(e.ip6 == nil && e.staticIP6 == nil)
    }
}

@Suite struct PortSpecTests {
    @Test func parsesCommonForms() {
        #expect(PortSpec.parse("80")?.port == 80 && PortSpec.parse("80")?.proto == "tcp")
        #expect(PortSpec.parse("53/udp")?.proto == "udp")
        #expect(PortSpec.parse("80/")?.proto == "tcp")
    }

    @Test func hostileKeysReturnNilInsteadOfTrapping() {
        for key in ["", "/", "/tcp", "x/tcp", "//", " "] { #expect(PortSpec.parse(key) == nil) }
    }

    @Test func linkEnvSkipsHostileExposedPorts() {
        var config = ContainerConfig()
        config.ExposedPorts = ["": EmptyStruct(), "/": EmptyStruct(), "8080/tcp": EmptyStruct()]
        let target = ContainerRecord(id: "a", name: "a", created: Date(), image: "i", imageID: "x", config: config, hostConfig: HostConfig())
        let env = Engine.linkEnv([(target: target, alias: "db")], of: target)
        #expect(env.contains { $0.hasPrefix("DB_PORT=tcp://") && $0.hasSuffix(":8080") })
    }
}

@Suite struct EngineHardeningTests {
    @Test func emptyIPRangeIsRejectedAndAllocateDoesNotTrap() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        for range in ["10.9.0.255/32", "10.9.0.0/32"] {
            var n = NetworkCreateRequest(); n.Name = "r"; n.IPAM.Config = [IPAMPool(Subnet: "10.9.0.0/24", IPRange: range)]
            await #expect(throws: EngineError.self) { _ = try await engine.createNetwork(n) }
        }
        let net = try #require(IPv4Net(cidr: "10.9.0.0/24"))
        var ipam = IPAM(net: net, gateway: nil, range: IPv4Net(cidr: "10.9.0.255/32", prefixes: 1...32), label: "x")
        #expect(throws: EngineError.self) { try ipam.allocate(for: "a") }
        await engine.shutdown()
    }

    @Test func hostileExposedPortsDoNotTrapInspectOrPorts() async throws {
        var config = ContainerConfig()
        config.ExposedPorts = ["": EmptyStruct(), "/": EmptyStruct(), "8080/tcp": EmptyStruct()]
        var record = ContainerRecord(id: "a", name: "a", created: Date(), image: "i", imageID: "x", config: config, hostConfig: HostConfig())
        record.ports = ["/": [], "": []]
        let ports = await Engine(paths: tempPaths()).ports(record)
        #expect(ports.map(\.PrivatePort) == [8080])
    }

    @Test func subMillisecondHealthDurationsAreRejected() throws {
        var h = HealthConfig()
        try Engine.validateHealthcheck(h)
        h.Interval = 5_000_000; h.Timeout = 0
        try Engine.validateHealthcheck(h)
        h.StartPeriod = 999_999
        #expect(throws: EngineError.self) { try Engine.validateHealthcheck(h) }
        h.StartPeriod = nil; h.Interval = 1
        #expect(throws: EngineError.self) { try Engine.validateHealthcheck(h) }
    }
}

@Suite struct EngineRaceTests {
    private func createTiny(_ engine: Engine) async throws -> String {
        let req = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(#"{"Image":"tiny"}"#.utf8))
        return try await engine.createContainer(name: nil, request: req).id
    }

    @Test func createIsRefusedWhileAnImageRemovalIsInFlight() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        await engine.setImageRemovals(1)
        await #expect(throws: EngineError.self) { _ = try await createTiny(engine) }
        await engine.setImageRemovals(0)
        _ = try await createTiny(engine)
        await engine.shutdown()
    }

    @Test func waitRemovedReturnsOnlyAfterRemoval() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let id = try await createTiny(engine)
        let finished = LockedFlag()
        let waiter = Task { _ = try await engine.waitContainer(id, condition: "removed"); finished.set() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!finished.value)
        try await engine.removeContainer(id)
        _ = try await waiter.value
        #expect(finished.value)
        #expect(await engine.containers[id] == nil)
        await engine.shutdown()
    }

    @Test func removedWaitReturnsTheRemovalResultNotAnEarlierExit() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let id = try await createTiny(engine)
        let waiter = Task { try await engine.waitContainer(id, condition: "removed") }
        try await Task.sleep(for: .milliseconds(200))
        await engine.resumeWaiters(id, WaitResult(StatusCode: 7, Error: nil))   // an earlier run exits with 7
        try await Task.sleep(for: .milliseconds(200))
        try await engine.removeContainer(id)
        #expect(try await waiter.value.StatusCode == 0)
        await engine.shutdown()
    }

    @Test func imageHealthcheckIntervalIsValidatedAtCreate() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        var cfg = try await makeImage(engine).config
        var h = ImageConfig.Health(); h.test = ["CMD", "true"]; h.interval = 1
        cfg.config?.healthcheck = h
        _ = try await engine.imageStore.register(config: cfg, layers: try await engine.imageStore.resolve("tiny").layers, tags: ["tiny:latest"])
        await #expect(throws: EngineError.self) { _ = try await createTiny(engine) }
        await engine.shutdown()
    }

    @Test func finishedExecsSurviveCountEvictionDuringGraceAndFinishIsIdempotent() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let id = try await createTiny(engine)
        for i in 0..<60 { await engine.registerExec("e\(i)", in: id); await engine.execFinished("e\(i)", code: i) }
        #expect(try await engine.inspectExec("e0").ExitCode == 0)
        await engine.execFinished("e1", code: 99)   // second finish is ignored
        #expect(try await engine.inspectExec("e1").ExitCode == 1)
        await engine.expireExecGrace("e0")
        await engine.registerExec("e61", in: id); await engine.execFinished("e61", code: 0)
        await #expect(throws: EngineError.self) { _ = try await engine.inspectExec("e0") }
        await engine.shutdown()
    }

    @Test func finishedExecLeavesExecIDs() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        let id = try await createTiny(engine)
        await engine.registerExec("e1", in: id)
        #expect(try await engine.inspectContainer(id).ExecIDs == ["e1"])
        await engine.execFinished("e1", code: 0)
        #expect(try await engine.inspectContainer(id).ExecIDs == nil)
        await engine.shutdown()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

private extension Engine {
    func setImageRemovals(_ n: Int) { imageRemovals = n }
    func expireExecGrace(_ id: String) { execs[id]?.finished = Date(timeIntervalSinceNow: -3600) }
    func registerExec(_ id: String, in container: String) {
        containers[container]?.execIDs.append(id)
        execs[id] = ExecRecord(id: id, containerID: container, config: ExecConfig())
    }
}
