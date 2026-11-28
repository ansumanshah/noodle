import Foundation
import CFNetwork
import NoodleCore

extension RegistryClient {
    // MARK: manifests

    public func manifest(_ ref: ImageReference, reference: String? = nil, credential: RegistryCredential? = nil) async throws -> ManifestResponse {
        let (scheme, host) = await base(for: ref)
        let r = reference ?? ref.reference
        let scope = "repository:\(ref.path):pull"
        guard let url = URL(string: "\(scheme)://\(host)/v2/\(ref.path)/manifests/\(r)") else { throw ImageError.invalid("bad reference \(ref)") }
        let (data, resp) = try await authorized({ auth in
            var q = URLRequest(url: url, timeoutInterval: 60)
            q.setValue(MediaType.acceptManifests, forHTTPHeaderField: "Accept")
            if let auth { q.setValue(auth, forHTTPHeaderField: "Authorization") }
            return q
        }, scheme: scheme, host: host, scope: scope, credential: credential, send: { try await self.transport.data($0) })
        guard resp.statusCode == 200 else { throw fail(resp, data, what: "manifest for \(ref.familiar)") }
        let mt = (resp.value(forHTTPHeaderField: "Content-Type") ?? MediaType.dockerManifest).split(separator: ";").first.map(String.init) ?? MediaType.dockerManifest
        let digest = Digest.sha256(data)
        if r.contains(":"), r != digest { throw ImageError.digestMismatch(expected: r, actual: digest) }
        if let advertised = resp.value(forHTTPHeaderField: "Docker-Content-Digest"), advertised != digest {
            throw ImageError.digestMismatch(expected: advertised, actual: digest)
        }
        return ManifestResponse(data: data, mediaType: mt, digest: digest)
    }

    /// Digest the registry currently serves for `ref`, from a HEAD request (no body, no pull-rate cost).
    /// Nil on any non-200 answer or a missing header, so callers fall back to the full pull and its errors.
    public func manifestDigest(_ ref: ImageReference, credential: RegistryCredential? = nil) async -> String? {
        let (scheme, host) = await base(for: ref)
        guard let url = URL(string: "\(scheme)://\(host)/v2/\(ref.path)/manifests/\(ref.reference)") else { return nil }
        guard let (_, resp) = try? await authorized({ auth in
            var q = URLRequest(url: url, timeoutInterval: 30)
            q.httpMethod = "HEAD"
            q.setValue(MediaType.acceptManifests, forHTTPHeaderField: "Accept")
            if let auth { q.setValue(auth, forHTTPHeaderField: "Authorization") }
            return q
        }, scheme: scheme, host: host, scope: "repository:\(ref.path):pull", credential: credential, send: { try await self.transport.data($0) }),
              resp.statusCode == 200, let d = resp.value(forHTTPHeaderField: "Docker-Content-Digest"), Digest.isValid(d) else { return nil }
        return d
    }

    /// Resolve an index to the manifest for `platform`.
    public func resolve(_ ref: ImageReference, platform: Platform, credential: RegistryCredential? = nil) async throws -> (top: ManifestResponse, image: ManifestResponse) {
        let top = try await manifest(ref, credential: credential)
        guard MediaType.isIndex(top.mediaType) else { return (top, top) }
        let index = try JSONDecoder().decode(Manifest.self, from: top.data)
        let candidates = index.manifests ?? []
        let pick = candidates.first {
            guard let p = $0.platform else { return false }
            return platform.matches(os: p.os, architecture: p.architecture, variant: p.variant)
        }
        guard let chosen = pick else { throw ImageError.noMatchingPlatform("\(platform) in the manifest list entries") }
        let m = try await manifest(ref, reference: chosen.digest, credential: credential)
        return (top, m)
    }
}
