import Foundation
import NoodleCore

/// A create response alone does not mean the importer created a volume.
private struct VolumeImportOwnership {
    static let label = "dev.getnoodle.import-owner"
    let target: String
    let token = UUID().uuidString

    func matches(_ volume: JSON?) -> Bool {
        volume?["Name"] as? String == target && (volume?["Labels"] as? JSON)?[Self.label] as? String == token
    }

    func isCurrent(_ endpoint: EngineEndpoint) throws -> Bool {
        let reply = try endpoint.object("GET", "/volumes/\(urlEscape(target))", ok: [404])
        return reply.status == 200 && matches(reply.value as? JSON)
    }
}

/// Volume bytes with ownership and modes: tar out of the source volume, tar into the target volume, then compare manifests.
func copyVolume(source: String, target: String, helperImage: String, labels: JSON, from src: EngineEndpoint, to dst: EngineEndpoint,
                tmp: URL, attempts: Int) throws {
    let up = tmp.appendingPathComponent("vol-\(UUID().uuidString).tar"), back = tmp.appendingPathComponent("vol-\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: up); try? FileManager.default.removeItem(at: back) }
    let ownership = VolumeImportOwnership(target: target)
    do {
        var ownedLabels = labels
        ownedLabels[VolumeImportOwnership.label] = ownership.token
        // Docker create is idempotent: an existing volume comes back with its original labels.
        let made = try dst.object("POST", "/volumes/create", json: ["Name": target, "Labels": ownedLabels]).value as? JSON
        guard ownership.matches(made) else { throw ImportError.fatal("volume \(target) belongs to another client; preserved") }
        try retrying(source, attempts: attempts) {
            try withVolumeHelper(src, image: helperImage, volume: source, readOnly: true) { id in try download(src, "/containers/\(id)/archive?path=/v", to: up) }
            guard try ownership.isCurrent(dst) else { throw ImportError.fatal("volume \(target) changed during import; preserved") }
            try withVolumeHelper(dst, image: helperImage, volume: target) { id in
                guard try ownership.isCurrent(dst) else { throw ImportError.fatal("volume \(target) changed during import; preserved") }
                try dst.call("PUT", "/containers/\(id)/archive?path=/&copyUIDGID=true", body: .file(up), headers: ["Content-Type": "application/x-tar"])
                try download(dst, "/containers/\(id)/archive?path=/v", to: back)
            }
            let diff = TarManifest.differences(try TarManifest.manifest(of: up), try TarManifest.manifest(of: back))
            if !diff.isEmpty { throw ImportError.transient("volume \(source) differs after copy: \(diff.joined(separator: "; "))") }
        }
        try dst.checkCancellation()
    } catch {
        let original = error
        try dst.cleanup {
            // Also check after a failed create: it may have committed before the reply was lost.
            if try ownership.isCurrent(dst) {
                try dst.call("DELETE", "/volumes/\(urlEscape(target))?force=1", ok: [404])
            }
        }
        throw original
    }
}
