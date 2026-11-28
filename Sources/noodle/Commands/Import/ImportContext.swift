import Foundation
import NoodleCore

/// State shared by one import run: the two engines, the policy and what the run changed on the target.
final class ImportContext {
    let src: EngineEndpoint, dst: EngineEndpoint, tmp: URL
    let policy: ImportConflictPolicy, attempts: Int, dryRun: Bool
    private var volumeTargets: [String: String] = [:]
    private var helperAdded: String?
    private var helperChosen: String?

    init(src: EngineEndpoint, dst: EngineEndpoint, tmp: URL, options: (ImportConflictPolicy, Int, Bool)) {
        (self.src, self.dst, self.tmp) = (src, dst, tmp)
        (policy, attempts, dryRun) = options
    }

    func cleanup() throws {
        if let image = helperAdded {
            _ = try dst.call("DELETE", "/images/\(urlEscape(image))", ok: [404, 409])
            helperAdded = nil
        }
    }

    private func splitRef(_ ref: String) -> (repo: String, tag: String) {
        if let c = ref.lastIndex(of: ":"), !ref[c...].contains("/") { return (String(ref[..<c]), String(ref[ref.index(after: c)...])) }
        return (ref, "latest")
    }

    func importImage(_ image: ImageInfo) throws -> String {
        if image.tags.isEmpty {
            // Digest-pinned and untagged: load by ID so no digest reference is used as a tag name.
            switch ImportPlan.untaggedImageAction(id: image.id, targetHas: { (try? dst.exists("/images/\(urlEscape($0))/json")) == true }) {
            case .present: return "already present and identical"
            case .copy(let names):
                if dryRun { return "would copy \(image.refs[0]) (\(String(format: "%.1f", Double(image.size) / 1_048_576)) MiB)" }
                try copyImage(names: names, from: src, to: dst, tmp: tmp, attempts: attempts)
                return "copied \(image.refs[0]) by ID, layers verified"
            }
        }
        var names: [String] = [], present = 0
        let source = try src.imageIdentity(image.refs[0])
        for tag in image.refs {
            guard try dst.exists("/images/\(urlEscape(tag))/json") else { names.append(tag); continue }
            if try dst.matchesImage(source, as: tag) { present += 1; continue }
            switch policy {
            case .skip: continue
            case .overwrite: names.append(tag)
            case .rename:
                names.append(tag)
                if !dryRun {
                    let (repo, t) = splitRef(tag)
                    try dst.call("POST", "/images/\(urlEscape(tag))/tag?repo=\(urlEscape(repo))&tag=\(urlEscape(t + "-before-import"))")
                }
            }
        }
        if names.isEmpty { return present == image.refs.count ? "already present and identical" : "skipped (tag exists with different content; use --on-conflict)" }
        if dryRun { return "would copy \(names.joined(separator: ", ")) (\(String(format: "%.1f", Double(image.size) / 1_048_576)) MiB)" }
        try copyImage(names: names, from: src, to: dst, tmp: tmp, attempts: attempts)
        return "copied \(names.joined(separator: ", ")), layers verified"
    }

    /// Smallest tagged source image that can stay running (`sleep`), present on the target too, used only to mount
    /// volumes for the archive API. A static-binary image has no `sleep`, and an archive PUT to a container that never
    /// started does not reach its volume mounts.
    private func helperImage(_ images: [ImageInfo]) throws -> String {
        if let h = helperChosen { return h }
        let candidates = images.filter { !$0.tags.isEmpty }.sorted { $0.size < $1.size }
        guard !candidates.isEmpty else {
            throw ImportError.fatal("the source has no tagged image, so volumes cannot be read through the API")
        }
        for image in candidates {
            let tag = image.tags[0]
            let existing = try dst.exists("/images/\(urlEscape(tag))/json")
            if existing, try !dst.matchesImage(src.imageIdentity(tag), as: tag) { continue }
            guard canStayRunning(tag) else { continue }
            if !existing {
                try copyImage(names: [tag], from: src, to: dst, tmp: tmp, attempts: attempts)
                helperAdded = tag
            }
            helperChosen = tag
            return tag
        }
        throw ImportError.fatal("no compatible tagged source image can run `sleep` and mount the volume on both engines")
    }

    private func canStayRunning(_ tag: String) -> Bool {
        let spec: JSON = ["Image": tag, "Entrypoint": [String](), "Cmd": ["sleep", "3600"],
                          "NetworkDisabled": true, "HostConfig": ["NetworkMode": "none"]]
        guard let made = try? src.object("POST", "/containers/create", json: spec).value as? JSON,
              let id = made["Id"] as? String else { return false }
        defer { _ = try? src.call("DELETE", "/containers/\(urlEscape(id))?force=1", ok: [404]) }
        guard (try? src.call("POST", "/containers/\(urlEscape(id))/start", ok: [304]).status).map({ $0 == 204 || $0 == 304 }) == true,
              let info = try? src.object("GET", "/containers/\(urlEscape(id))/json").value as? JSON else { return false }
        return (info["State"] as? JSON)?["Running"] as? Bool == true
    }

    private func volumesInUseOnTarget() throws -> Set<String> {
        let ids = try dst.containers().compactMap { $0["Id"] as? String }
        return ImportPlan.volumesInUse(containerInspects: try ids.map { try dst.inspect("containers", $0) })
    }

    func importVolume(_ v: JSON, images: [ImageInfo]) throws -> String {
        let name = v["Name"] as? String ?? ""
        guard (v["Driver"] as? String ?? "local") == "local", (v["Options"] as? JSON)?.isEmpty ?? true else {
            return "skipped (non-local or option-backed volume)"
        }
        let existing = Set(try dst.volumes().compactMap { $0["Name"] as? String })
        let decision = ImportNaming.decide(name, exists: { existing.contains($0) }, policy: policy)
        if dryRun {
            switch decision {
            case .skip: return "skipped (exists)"
            case .replace(let target), .create(let target): return "would copy to \(target)"
            }
        }
        if case .replace(let target) = decision, try volumesInUseOnTarget().contains(target) {
            volumeTargets[name] = target
            return "skipped (in use by a container on Noodle; left alone)"
        }
        let helper = try helperImage(images)
        switch decision {
        case .skip:
            volumeTargets[name] = name
            let same = try volumeManifest(src, image: helper, volume: name, tmp: tmp) == volumeManifest(dst, image: helper, volume: name, tmp: tmp)
            return same ? "already present and identical" : "skipped (exists with different content; use --on-conflict)"
        case .replace(let target), .create(let target):
            volumeTargets[name] = target
            let labels = v["Labels"] as? JSON ?? [:]
            if case .replace = decision {
                // Verify the copy under a temporary name first; the original goes only after that succeeds.
                let staged = target.prefix(200) + "-noodle-import-" + UUID().uuidString.prefix(8).lowercased()
                try copyVolume(source: name, target: staged, helperImage: helper, labels: labels, from: src, to: dst, tmp: tmp, attempts: attempts)
                do { try dst.call("DELETE", "/volumes/\(urlEscape(target))?force=1", ok: [404]) } catch {
                    // The original is untouched (for example still in use), so the staging copy is not needed.
                    try? dst.cleanup { try dst.call("DELETE", "/volumes/\(urlEscape(staged))?force=1", ok: [404]) }
                    throw error
                }
                do {
                    try copyVolume(source: staged, target: target, helperImage: helper, labels: labels, from: dst, to: dst, tmp: tmp, attempts: attempts)
                } catch {
                    throw ImportError.fatal("could not rebuild volume \(target); the verified copy is kept as \(staged): \(error)")
                }
                try dst.cleanup { try dst.call("DELETE", "/volumes/\(urlEscape(staged))?force=1", ok: [404]) }
                return "copied to \(target), contents, owners and modes verified"
            }
            try copyVolume(source: name, target: target, helperImage: helper, labels: labels, from: src, to: dst, tmp: tmp, attempts: attempts)
            return "copied to \(target), contents, owners and modes verified"
        }
    }

    func importContainer(_ c: JSON) throws -> String {
        let name = String(((c["Names"] as? [String])?.first ?? "").dropFirst())
        let info = try src.inspect("containers", c["Id"] as? String ?? name)
        var config = info["Config"] as? JSON ?? [:]
        var host = info["HostConfig"] as? JSON ?? [:]
        let image = config["Image"] as? String ?? ""
        let taken = Set(try dst.containers().flatMap { ($0["Names"] as? [String] ?? []).map { String($0.dropFirst()) } })
        let decision = ImportNaming.decide(name, exists: { taken.contains($0) }, policy: policy)
        guard decision != .skip else { return "skipped (a container with this name exists; use --on-conflict)" }
        var notes: [String] = []
        if image.contains("@sha256:") {
            // A digest reference is not a tag name: move the image by ID and let the container use the ID.
            let id = try src.imageIdentity(image).id
            if try !dst.exists("/images/\(urlEscape(id))/json") {
                if dryRun { notes.append("would copy image \(image)") } else {
                    try copyImage(names: [id], from: src, to: dst, tmp: tmp, attempts: attempts)
                    notes.append("copied image \(image)")
                }
            }
            if !dryRun { config["Image"] = id }
        } else if try dst.exists("/images/\(urlEscape(image))/json") {
            guard try dst.matchesImage(src.imageIdentity(image), as: image) else {
                throw ImportError.fatal("the target image \(image) differs from the source. Import its image first with the intended conflict policy")
            }
        } else {
            if dryRun { notes.append("would copy image \(image)") } else {
                try copyImage(names: [image], from: src, to: dst, tmp: tmp, attempts: attempts)
                notes.append("copied image \(image)")
            }
        }
        var missing = Set<String>()
        let known = Set(try dst.volumes().compactMap { $0["Name"] as? String })
        func mapped(_ volume: String) -> String {
            if let target = volumeTargets[volume] { return target }
            if !known.contains(volume) { missing.insert(volume) }
            return volume
        }
        let binds = host["Binds"] as? [String] ?? []
        host["Binds"] = binds.map { bind -> String in
            var parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count > 1, let first = parts.first, !first.hasPrefix("/") {
                parts[0] = mapped(first)
            }
            return parts.joined(separator: ":")
        }
        var mounts = (host["Mounts"] as? [JSON] ?? []).map { m -> JSON in
            var m = m
            if m["Type"] as? String == "volume", let s = m["Source"] as? String, !s.isEmpty { m["Source"] = mapped(s) }
            return m
        }
        // Some engines omit the requested volume mount from HostConfig but retain it in inspect.
        // Only recover named volumes. Source paths in this list belong to the other engine's VM.
        var destinations = Set(mounts.compactMap { $0["Target"] as? String })
        for bind in binds {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false)
            if let target = parts.dropFirst(parts.count > 1 ? 1 : 0).first { destinations.insert(String(target)) }
        }
        for mount in info["Mounts"] as? [JSON] ?? [] {
            guard mount["Type"] as? String == "volume", let volume = mount["Name"] as? String, !volume.isEmpty,
                  let target = mount["Destination"] as? String, target.hasPrefix("/"),
                  let readWrite = mount["RW"] as? Bool, destinations.insert(target).inserted else { continue }
            mounts.append(["Type": "volume", "Source": mapped(volume), "Target": target,
                           "ReadOnly": !readWrite, "VolumeOptions": ["NoCopy": true]])
        }
        host["Mounts"] = mounts
        if !missing.isEmpty { notes.append("volumes not imported, target starts them empty: \(missing.sorted().joined(separator: ", "))") }
        var networking: JSON = [:]
        let networks = (info["NetworkSettings"] as? JSON)?["Networks"] as? JSON ?? [:]
        if let net = ImportPlan.network(hostConfig: host, networks: networks) {
            // Containers sharing a network find it already there after the first one.
            if !dryRun, try !dst.exists("/networks/\(urlEscape(net.name))") { try dst.call("POST", "/networks/create", json: ["Name": net.name, "Driver": "bridge"]) }
            networking = ["EndpointsConfig": [net.name: ["Aliases": net.aliases]]]
        }
        config["HostConfig"] = host
        config["NetworkingConfig"] = networking
        let target: String
        switch decision {
        case .create(let n): target = n
        case .replace(let n): target = n; if !dryRun { removeContainer(dst, n) }
        case .skip: return ""
        }
        if dryRun { return "would create \(target)" + (notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")") }
        _ = try dst.call("POST", "/containers/create?name=\(urlEscape(target))", json: config)
        return "created \(target), not started; writable-layer changes are not copied" + (notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")")
    }
}
