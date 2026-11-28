import Foundation
import NoodleCore

/// Read-only projection of ImageStore's catalog. Config and registry metadata
/// are deliberately omitted. Blobs are copied and verified so concurrent prune
/// cannot leave a successful-looking partial export, or expose store files to a helper.
private struct ScanImageRecord: Decodable {
    struct Layer: Decodable {
        let digest: String
        let mediaType: String
        let size: Int64
    }
    let id: String
    let layers: [Layer]
}

func scanExport(_ image: String, to layout: URL) throws -> String {
    // Inspect and export are host-only operations; never call ensureRunning,
    // pull, or a guest operation. The daemon must already be listening.
    let reply = try DockerHTTP(socketPath: socketPath).request("GET", "/images/\(urlEscape(image))/json")
    guard reply.status == 200 else {
        if reply.status == 404 { throw CLIError("No such image: \(image). Pull it before scanning.") }
        throw CLIError("cannot inspect image (HTTP \(reply.status)): \(String(decoding: reply.body, as: UTF8.self))")
    }
    guard let info = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any], let id = info["Id"] as? String else {
        throw CLIError("invalid image inspection response")
    }
    let records = try JSONDecoder().decode([String: ScanImageRecord].self, from: Data(contentsOf: paths.imagesFile))
    guard let record = records[id] else { throw CLIError("image disappeared from the host store: \(image)") }
    let blobs = layout.appendingPathComponent("blobs/sha256")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    func copyBlob(_ digest: String) throws -> Int64 {
        guard digest.hasPrefix("sha256:"), Digest.isValid(digest) else { throw CLIError("invalid image blob digest") }
        let hex = String(digest.dropFirst(7))
        let dest = blobs.appendingPathComponent(hex)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: paths.blobsDir.appendingPathComponent("sha256/" + hex), to: dest)
        }
        guard try Digest.sha256(file: dest) == digest else { throw CLIError("SHA-256 mismatch for image blob \(digest)") }
        return try (FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    let configSize = try copyBlob(record.id)
    var layers: [[String: Any]] = []
    for layer in record.layers {
        let size = try copyBlob(layer.digest)
        guard size == layer.size else { throw CLIError("image layer size mismatch: \(layer.digest)") }
        let mediaType: String
        switch layer.mediaType {
        case "application/vnd.docker.image.rootfs.diff.tar.gzip":
            mediaType = "application/vnd.oci.image.layer.v1.tar+gzip"
        case "application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar+gzip", "application/vnd.oci.image.layer.v1.tar+zstd":
            mediaType = layer.mediaType
        default: throw CLIError("unsupported image layer media type: \(layer.mediaType)")
        }
        layers.append(["mediaType": mediaType, "digest": layer.digest, "size": size])
    }
    let manifest: [String: Any] = ["schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": ["mediaType": "application/vnd.oci.image.config.v1+json", "digest": record.id, "size": configSize], "layers": layers]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    let digest = Digest.sha256(data)
    try data.write(to: blobs.appendingPathComponent(String(digest.dropFirst(7))))
    let index: [String: Any] = ["schemaVersion": 2, "manifests": [["mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": digest, "size": data.count]]]
    try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: layout.appendingPathComponent("index.json"))
    try Data("{\"imageLayoutVersion\":\"1.0.0\"}".utf8).write(to: layout.appendingPathComponent("oci-layout"))
    return id
}
