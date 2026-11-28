import Foundation
import NoodleCore

// One side of an import: a Docker Engine API endpoint plus the few calls the importer needs.

typealias JSON = [String: Any]

/// Progress and per-item results: stdout, or stderr under --json.
func importLog(_ s: String) { note(s) }

func urlEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~:/@"))) ?? s
}

func retrying<T>(_ label: String, attempts: Int, _ body: () throws -> T) throws -> T {
    var attempt = 1
    while true {
        do { return try body() } catch let e as ImportError where e.retryable && attempt < attempts {
            importLog("  retry \(attempt)/\(attempts - 1) for \(label): \(e.message)")
            Thread.sleep(forTimeInterval: 0.3 * Double(attempt))
            attempt += 1
        }
    }
}

struct ImageInfo {
    var id: String; var tags: [String]; var size: Int; var digests: [String] = []
    /// Tags, or digest references for a digest-pinned image that has no tag.
    var refs: [String] { ImportPlan.imageRefs(tags: tags, digests: digests) }
}

struct ImportImageIdentity {
    let id: String
    let layers: [String]
}

final class EngineEndpoint {
    let name: String
    let http: DockerHTTP
    private let imageCatalog: URL?
    init(name: String, socketPath: String, cancellation: ImportCancellation? = nil, imageCatalog: URL? = nil) {
        self.name = name; self.imageCatalog = imageCatalog
        http = DockerHTTP(socketPath: socketPath, cancellation: cancellation)
    }
    func checkCancellation() throws { try http.cancellation?.check() }
    func cleanup<T>(_ work: () throws -> T) rethrows -> T {
        if let cancellation = http.cancellation { return try cancellation.cleanup(work) }
        return try work()
    }

    @discardableResult
    func call(_ method: String, _ path: String, json: Any? = nil, ok: Set<Int> = [], sink: ((Data) throws -> Void)? = nil,
              body: RequestBody? = nil, headers: [String: String] = [:]) throws -> HTTPReply {
        var h = headers
        var rb = body ?? .none
        if let json { rb = .data(try JSONSerialization.data(withJSONObject: json)); h["Content-Type"] = "application/json" }
        try checkCancellation()
        let r: HTTPReply
        do {
            if case .file = rb { r = try http.request(method, path, headers: h, body: rb, sink: sink) }
            else if sink == nil, let cancellation = http.cancellation {
                r = try cancellation.finish { try http.request(method, path, headers: h, body: rb, sink: sink) }
            } else { r = try http.request(method, path, headers: h, body: rb, sink: sink) }
        } catch { try checkCancellation(); throw error }
        if (200..<300).contains(r.status) || ok.contains(r.status) { return r }
        let msg = (try? JSONSerialization.jsonObject(with: r.body) as? JSON)?["message"] as? String ?? String(decoding: r.body, as: UTF8.self)
        let text = "\(name): \(method) \(path.split(separator: "?").first ?? "") -> \(r.status) \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        throw r.status >= 500 ? ImportError.transient(text) : ImportError.fatal(text)
    }

    func object(_ method: String, _ path: String, json: Any? = nil, ok: Set<Int> = []) throws -> (status: Int, value: Any?) {
        let r = try call(method, path, json: json, ok: ok)
        return (r.status, r.body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: r.body))
    }

    func exists(_ path: String) throws -> Bool { try call("GET", path, ok: [404]).status == 200 }

    func images(all: Bool = false) throws -> [ImageInfo] {
        let list = try object("GET", all ? "/images/json?all=1" : "/images/json").value as? [JSON] ?? []
        return list.map { ImageInfo(id: $0["Id"] as? String ?? "", tags: ($0["RepoTags"] as? [String] ?? []).filter { $0 != "<none>:<none>" }, size: $0["Size"] as? Int ?? 0, digests: $0["RepoDigests"] as? [String] ?? []) }
    }

    func volumes() throws -> [JSON] { ((try object("GET", "/volumes").value as? JSON)?["Volumes"] as? [JSON]) ?? [] }

    func containers() throws -> [JSON] { try object("GET", "/containers/json?all=1").value as? [JSON] ?? [] }

    func inspect(_ kind: String, _ ref: String) throws -> JSON {
        try object("GET", "/\(kind)/\(urlEscape(ref))/json").value as? JSON ?? [:]
    }

    func imageIdentity(_ image: String) throws -> ImportImageIdentity {
        let info = try inspect("images", image)
        guard let id = info["Id"] as? String, id.hasPrefix("sha256:"), Digest.isValid(id),
              let root = info["RootFS"] as? JSON else {
            throw ImportError.fatal("\(name): invalid image identity for \(image)")
        }
        // Docker can report null for a zero-layer image.
        let layers = root["Layers"] as? [String] ?? []
        guard root["Layers"] is [String] || (root["Type"] as? String == "layers" && root["Layers"] is NSNull),
              layers.allSatisfy({ $0.hasPrefix("sha256:") && Digest.isValid($0) }) else {
            throw ImportError.fatal("\(name): invalid image layers for \(image)")
        }
        return ImportImageIdentity(id: id, layers: layers)
    }

    func matchesImage(_ source: ImportImageIdentity, as image: String) throws -> Bool {
        let target = try imageIdentity(image)
        guard source.id == target.id else { return false }
        if source.layers == target.layers { return true }
        // Some engines report the compressed layer digests in RootFS.Layers.
        // The local catalog records the digest of each blob Noodle hashed at load.
        guard let imageCatalog else { return false }
        struct Record: Decodable {
            struct Layer: Decodable { let digest: String }
            let layers: [Layer]
        }
        let catalog = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: imageCatalog))
        return catalog[target.id]?.layers.map(\.digest) == source.layers
    }
}

/// Image bytes: `GET /images/get` on the source into a file, `POST /images/load` from that file on the target.
func copyImage(names: [String], from src: EngineEndpoint, to dst: EngineEndpoint, tmp: URL, attempts: Int) throws {
    let rollback = try ImageImportRollback(names: names, src: src, dst: dst)
    let file = tmp.appendingPathComponent("image-\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: file) }
    do {
        try retrying(names.joined(separator: ","), attempts: attempts) {
            try download(src, "/images/get?" + names.map { "names=" + urlEscape($0) }.joined(separator: "&"), to: file)
            let r = try dst.call("POST", "/images/load?quiet=1", body: .file(file), headers: ["Content-Type": "application/x-tar"])
            if String(decoding: r.body, as: UTF8.self).contains("\"error\"") {
                throw ImportError.fatal("\(dst.name) refused the image: \(String(decoding: r.body, as: UTF8.self).prefix(300))")
            }
            for name in names {
                let source = try src.imageIdentity(name)
                guard try dst.matchesImage(source, as: name) else {
                    throw ImportError.transient("image identity or layers of \(name) differ after load")
                }
            }
        }
        try dst.checkCancellation()
    } catch { let original = error; try dst.cleanup { try rollback.restore(dst) }; throw original }
}

func download(_ src: EngineEndpoint, _ path: String, to file: URL) throws {
    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
    let h = try FileHandle(forWritingTo: file)
    defer { try? h.close() }
    try src.call("GET", path, sink: { try h.write(contentsOf: $0) })
}

func removeContainer(_ e: EngineEndpoint, _ id: String) {
    _ = try? e.call("DELETE", "/containers/\(urlEscape(id))?force=1", ok: [404])
}

/// A container that mounts `volume` at /v, only so the archive API can reach the volume. It idles on `sleep` when the
/// image has one (Noodle only mounts volumes into a started container); otherwise it stays created, which is enough for Docker.
func withVolumeHelper<T>(_ e: EngineEndpoint, image: String, volume: String, readOnly: Bool = false,
                         _ body: (String) throws -> T) throws -> T {
    let name = "noodle-import-\(IDs.random64().prefix(12))"
    let mount: JSON = ["Type": "volume", "Source": volume, "Target": "/v", "ReadOnly": readOnly, "VolumeOptions": ["NoCopy": true]]
    let spec: JSON = ["Image": image, "Entrypoint": [String](), "Cmd": ["sleep", "3600"], "NetworkDisabled": true, "HostConfig": ["Mounts": [mount]]]
    let result: Result<T, any Error>
    do {
        let made = try e.object("POST", "/containers/create?name=\(name)", json: spec).value as? JSON
        guard let id = made?["Id"] as? String else { throw ImportError.fatal("\(e.name): temporary container was not created") }
        _ = try? e.call("POST", "/containers/\(id)/start", ok: [304])
        result = .success(try body(id))
    } catch { result = .failure(error) }
    _ = try e.cleanup { try e.call("DELETE", "/containers/\(name)?force=1&v=1", ok: [404]) }
    return try result.get()
}

/// Manifest of a volume's current contents, used to tell "already imported" from "same name, different data".
func volumeManifest(_ e: EngineEndpoint, image: String, volume: String, tmp: URL) throws -> [String: String] {
    let file = tmp.appendingPathComponent("man-\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: file) }
    try withVolumeHelper(e, image: image, volume: volume, readOnly: true) { id in try download(e, "/containers/\(id)/archive?path=/v", to: file) }
    return try TarManifest.manifest(of: file)
}
