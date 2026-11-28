import Foundation
import Testing
@testable import NoodleCore

@Suite struct CodecTests {
    @Test func lengthPrefixRoundTrip() throws {
        let payload = Data(#"{"id":1,"op":"ping"}"#.utf8)
        let framed = LengthPrefixed.encode(payload)
        #expect(framed.count == payload.count + 4)
        #expect([UInt8](framed.prefix(4)) == [0, 0, 0, UInt8(payload.count)])
        var d = ControlFrameDecoder()
        d.append(framed)
        #expect(try d.next() == payload)
        #expect(try d.next() == nil)
    }

    @Test func decoderHandlesSplitAndCoalescedFrames() throws {
        let a = Data("one".utf8), b = Data("two!".utf8)
        let wire = LengthPrefixed.encode(a) + LengthPrefixed.encode(b)
        var d = ControlFrameDecoder()
        var got: [Data] = []
        for byte in wire {          // one byte at a time
            d.append(Data([byte]))
            while let f = try d.next() { got.append(f) }
        }
        #expect(got == [a, b])
        var e = ControlFrameDecoder()
        e.append(wire)
        #expect(try e.next() == a)
        #expect(try e.next() == b)
    }

    @Test func requestEncodesFlat() throws {
        let req = GuestRequest(id: 7, op: "kill", args: ["container": "abc", "signal": 15])
        let frame = try req.encodedFrame()
        var d = ControlFrameDecoder(); d.append(frame)
        let obj = try JSONDecoder().decode(JSONValue.self, from: try #require(try d.next()))
        #expect(obj["id"]?.int == 7)
        #expect(obj["op"]?.string == "kill")
        #expect(obj["container"]?.string == "abc")
        #expect(obj["signal"]?.int == 15)
    }

    @Test func responsesAndEvents() throws {
        let ok = try GuestMessage.parse(Data(#"{"id":3,"ok":true,"pid":42}"#.utf8))
        guard case .response(let id, .success(let r)) = ok else { Issue.record("not ok"); return }
        #expect(id == 3); #expect(r["pid"]?.int == 42); #expect(r["ok"] == nil)

        let bad = try GuestMessage.parse(Data(#"{"id":4,"ok":false,"error":"no such container","errno":2}"#.utf8))
        guard case .response(_, .failure(let e)) = bad else { Issue.record("not error"); return }
        #expect(e.message == "no such container"); #expect(e.errno == 2)

        let ev = try GuestMessage.parse(Data(#"{"event":"exit","container":"c1","code":137}"#.utf8))
        guard case .event(.exit(let c, let code)) = ev else { Issue.record("not exit"); return }
        #expect(c == "c1"); #expect(code == 137)
        let oom = try GuestMessage.parse(Data(#"{"event":"oom","container":"c2"}"#.utf8))
        guard case .event(.oom("c2")) = oom else { Issue.record("not oom"); return }
        let ex = try GuestMessage.parse(Data(#"{"event":"exec_exit","exec":"e1","code":1}"#.utf8))
        guard case .event(.execExit("e1", 1)) = ex else { Issue.record("not exec_exit"); return }
    }

    @Test func streamFramesRoundTrip() throws {
        let frames = [StreamFrame(kind: .stdout, payload: Data("hello".utf8)),
                      StreamFrame.resize(rows: 24, cols: 80),
                      StreamFrame(kind: .exit, payload: Data([0, 0, 0, 3]))]
        var d = StreamFrameDecoder()
        for f in frames { d.append(f.encoded()) }
        var out: [StreamFrame] = []
        while let f = try d.next() { out.append(f) }
        #expect(out == frames)
        #expect(out[2].exitCode == 3)
        #expect([UInt8](out[1].payload) == [0, 24, 0, 80])
    }

    @Test func negativeExitCode() {
        let f = StreamFrame(kind: .exit, payload: Data([0xff, 0xff, 0xff, 0xff]))
        #expect(f.exitCode == -1)
    }

    @Test func oldGuestMountDecodesWithoutNoCopy() throws {
        let data = Data(#"{"kind":"volume","source":"v","target":"/data","read_only":false,"tmpfs_size":0}"#.utf8)
        let mount = try JSONDecoder().decode(GuestMount.self, from: data)
        #expect(mount.noCopy == nil)
    }

    @Test func specUsesProtocolKeys() throws {
        var spec = ContainerSpec()
        spec.argv = ["sh"]; spec.readOnly = true; spec.pidsLimit = 5; spec.`init` = true
        spec.ulimits = [GuestUlimit(name: "nofile", soft: 1234, hard: -1)]
        spec.sysctls = ["net.core.somaxconn": "1234"]
        spec.network = GuestNetwork(name: "bridge", ip: "172.18.0.2", gateway: "172.18.0.1", prefix: 16, mac: "02:42:ac:12:00:02")
        spec.mounts = [GuestMount(kind: "bind", source: "/Users/a", target: "/data", readOnly: true)]
        let json = try JSONValue(encoding: spec)
        #expect(json["read_only"]?.bool == true)
        #expect(json["init"]?.bool == true)
        #expect(json["pids_limit"]?.int == 5)
        #expect(json["ulimits"]?.array?.first?["hard"]?.int == -1)
        #expect(json["sysctls"]?["net.core.somaxconn"]?.string == "1234")
        #expect(json["network_mode"]?.string == "bridge")
        #expect(json["network"]?["prefix"]?.int == 16)
        #expect(json["mounts"]?.array?.first?["read_only"]?.bool == true)
        #expect(json["shm_size"]?.int == 67_108_864)
        let back: ContainerSpec = try json.decode()
        #expect(back == spec)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        old.removeValue(forKey: "init")
        let previous = try JSONDecoder().decode(ContainerSpec.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(previous.`init` == false)
    }
}

@Suite struct PathsAndSettingsTests {
    @Test func environmentOverridesRoot() {
        let p = NoodlePaths.resolve(environment: ["NOODLE_HOME": "/tmp/nh"])
        #expect(p.root.path == "/tmp/nh")
        #expect(p.socket.path == "/tmp/nh/run/docker.sock")
        #expect(p.settingsFile.path == "/tmp/nh/vm.json")
        let hex = String(repeating: "ab", count: 32)
        #expect(p.blobPath(digest: "sha256:" + hex).path == "/tmp/nh/blobs/sha256/" + hex)
    }

    @Test func defaultRootIsDotNoodle() {
        let p = NoodlePaths.resolve(environment: [:])
        #expect(p.root.lastPathComponent == ".noodle")
    }

    @Test func settingsFileAndEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = NoodlePaths(root: dir)
        try VMSettings(cpus: 3, memoryMiB: 2048).save(paths: paths)
        let loaded = VMSettings.load(paths: paths, environment: [:])
        #expect(loaded.cpus == 3); #expect(loaded.memoryMiB == 2048)
        let over = VMSettings.load(paths: paths, environment: ["NOODLE_CPUS": "6", "NOODLE_MEMORY_MIB": "4096"])
        #expect(over.cpus == 6); #expect(over.memoryMiB == 4096)
        let text = try String(contentsOf: paths.settingsFile, encoding: .utf8)
        #expect(text.contains("\"memory_mib\""))
    }

    @Test func digestHelpers() {
        #expect(Digest.sha256(Data("abc".utf8)) == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Digest.isValid("sha256:" + String(repeating: "0", count: 64)))
        #expect(!Digest.isValid("sha256:xyz"))
        var h = Digest.Hasher(); h.update(Data("a".utf8)); h.update(Data("bc".utf8))
        #expect(h.finalize() == Digest.sha256(Data("abc".utf8)))
        #expect(IDs.random64().count == 64)
    }
}
