import Foundation
import CryptoKit

extension RawSession {
    func prepare(options: [String: String], source: String, command: [String]) throws {
        let home = URL(fileURLWithPath: options["home"]!)
        var layers: [(URL, String, String, String, Int64)] = []
        var runtime: RawJSON = [:]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue {
            let tar = directory.appendingPathComponent("rootfs.tar")
            var env = ProcessInfo.processInfo.environment; env["COPYFILE_DISABLE"] = "1"
            try process(URL(fileURLWithPath: "/usr/bin/tar"), ["--format", "ustar", "-cf", tar.path, "-C", source, "."], environment: env)
            let digest = try hash(tar)
            layers.append((tar, digest, digest, "tar", try size(tar)))
        } else {
            let data = try Data(contentsOf: home.appendingPathComponent("images.json"))
            guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: RawJSON] else { throw rawError("invalid image catalog") }
            let matches = catalog.values.filter { image in
                let id = image["id"] as? String ?? ""
                return id == source || id == "sha256:" + source || (image["repoTags"] as? [String] ?? []).contains(source) || (image["repoTags"] as? [String] ?? []).contains(source + ":latest")
            }
            guard matches.count == 1, let image = matches.first else { throw rawError("image must already exist in --home (or supply a rootfs directory): \(source)") }
            guard image["architecture"] as? String == "arm64", image["os"] as? String == "linux" else { throw rawError("raw-run requires a linux/arm64 image") }
            runtime = (image["config"] as? RawJSON)?["config"] as? RawJSON ?? [:]
            for layer in image["layers"] as? [RawJSON] ?? [] {
                guard let digest = layer["digest"] as? String, let diff = layer["diffID"] as? String,
                      validDigest(digest), validDigest(diff), let media = layer["mediaType"] as? String,
                      let expected = layer["size"] as? NSNumber else { throw rawError("invalid layer metadata") }
                let file = home.appendingPathComponent("blobs/sha256/" + digest.dropFirst(7))
                guard try size(file) == expected.int64Value, try hash(file) == digest else { throw rawError("layer blob failed size/digest verification: \(digest)") }
                let format: String
                if media.contains("gzip") { format = "gzip" } else if media.contains("zstd") { format = "zstd" }
                else if media.hasSuffix(".tar") { format = "tar" } else { throw rawError("unsupported layer media: \(media)") }
                layers.append((file, digest, diff, format, expected.int64Value))
            }
        }
        var argv = runtime["Entrypoint"] as? [String] ?? []
        argv += command.isEmpty ? (runtime["Cmd"] as? [String] ?? []) : command
        guard !argv.isEmpty else { throw rawError("missing command") }
        let disk = directory.appendingPathComponent("disk.img")
        let fd = open(disk.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw rawError("cannot create temporary disk") }
        let resized = ftruncate(fd, 16 * 1024 * 1024 * 1024); close(fd)
        guard resized == 0 else { throw rawError("cannot size temporary disk") }
        let resources = URL(fileURLWithPath: options["resources"]!)
        var env = ProcessInfo.processInfo.environment; env["MKE2FS_CONFIG"] = resources.appendingPathComponent("mke2fs.conf").path
        try process(resources.appendingPathComponent("mke2fs"), ["-F", "-q", "-t", "ext4", "-b", "4096", "-J", "size=16", "-E", "nodiscard,lazy_itable_init=1,lazy_journal_init=0", disk.path], environment: env)
        let spec = MachineSpec(directory: directory, kernel: URL(fileURLWithPath: options["kernel"]!), initramfs: URL(fileURLWithPath: options["initramfs"]!), cpus: 2, memoryMiB: 2048, user: "root", uid: 0, host: "noodle-raw", share: nil, seed: false, workload: true)
        let vm = MachineVM(spec: spec) { [weak self] error in
            if let error { FileHandle.standardError.write(Data("noodle-machine: raw VM stopped: \(error)\n".utf8)) }
            self?.finish(1)
        }
        finishLock.lock()
        guard !finished else { finishLock.unlock(); throw rawError("raw-run cancelled") }
        machine = vm
        finishLock.unlock()
        let booted = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var bootError: Error?
        Task { do { try await vm.start() } catch { bootError = error }; booted.signal() }
        guard booted.wait(timeout: .now() + 30) == .success else { throw rawError("VM start timed out") }
        if let bootError { throw bootError }
        let deadline = Date().addingTimeInterval(30)
        var control: RawWire?
        while Date() < deadline {
            if let wire = try? connect(rawControlPort, timeout: 2), (try? wire.request(["op": "ping"])) != nil { control = wire; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let control else { throw rawError("Linux connection timed out") }
        for (url, digest, diff, media, bytes) in layers {
            let wire = try connect(rawStreamPort, timeout: 120)
            try wire.send(["op": "unpack_layer", "digest": digest, "diff_id": diff, "media": media, "size": bytes])
            _ = try wire.response()
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try wire.write(chunk) }
            shutdown(wire.fd, SHUT_WR)
            let result = try wire.response()
            guard result["diff_id"] as? String == diff else { throw rawError("unpacked layer digest mismatch") }
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let configuredCWD = runtime["WorkingDir"] as? String ?? ""
        let configuredUser = runtime["User"] as? String ?? ""
        let specJSON: RawJSON = ["layers": layers.reversed().map { $0.1 }, "argv": argv, "env": runtime["Env"] as? [String] ?? ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "cwd": configuredCWD.isEmpty ? "/" : configuredCWD, "user": configuredUser.isEmpty ? "0:0" : configuredUser, "tty": false, "stdin": false, "network_mode": "host", "privileged": true, "seccomp": "unconfined"]
        _ = try control.request(["op": "create", "container": id, "spec": specJSON])
        let output = try connect(rawStreamPort)
        try output.send(["op": "attach", "container": id, "stdin": false, "stdout": true, "stderr": true, "logs": true]); _ = try output.response()
        _ = try control.request(["op": "start", "container": id])
        // Output has no idle timeout: arbitrary commands may legitimately remain quiet.
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(output.fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        while true {
            let header = try output.read(5); let kind = header[0]
            let count = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count <= 16 * 1024 * 1024 else { throw rawError("oversized output frame") }
            let body = try output.read(Int(count))
            if kind == 1 { try FileHandle.standardOutput.write(contentsOf: body) }
            else if kind == 2 { try FileHandle.standardError.write(contentsOf: body) }
            else if kind == 3 {
                guard body.count == 4 else { throw rawError("invalid exit frame") }
                finish(Int32(bitPattern: body.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })); return
            }
        }
    }
}
