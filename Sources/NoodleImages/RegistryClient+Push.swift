import Foundation
import CFNetwork
import NoodleCore

extension RegistryClient {
    /// Upload a blob from a local file (monolithic upload: POST then PUT).
    public func pushBlob(_ ref: ImageReference, digest: String, file: URL, credential: RegistryCredential? = nil,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let (scheme, host) = await base(for: ref)
        let scope = "repository:\(ref.path):pull,push"
        guard let startURL = URL(string: "\(scheme)://\(host)/v2/\(ref.path)/blobs/uploads/") else { throw ImageError.invalid("bad url") }
        let (data, resp) = try await authorized({ auth in
            var q = URLRequest(url: startURL, timeoutInterval: 60); q.httpMethod = "POST"
            q.setValue("0", forHTTPHeaderField: "Content-Length")
            if let auth { q.setValue(auth, forHTTPHeaderField: "Authorization") }
            return q
        }, scheme: scheme, host: host, scope: scope, credential: credential, send: { try await self.transport.data($0) })
        guard resp.statusCode == 202, let loc = resp.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: loc, relativeTo: startURL)?.absoluteURL,
              uploadURL.scheme == startURL.scheme, uploadURL.host == startURL.host, uploadURL.port == startURL.port,
              var comps = URLComponents(url: uploadURL, resolvingAgainstBaseURL: true) else {
            throw fail(resp, data, what: "start upload")
        }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "digest", value: digest))
        comps.queryItems = items
        let auth = try await authorization(scheme: scheme, host: host, scope: scope, credential: credential)
        var put = URLRequest(url: comps.url!, timeoutInterval: 3600)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let auth { put.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (body, presp) = try await transport.upload(put, file: file, progress: progress)
        guard presp.statusCode == 201 || presp.statusCode == 204 else { throw fail(presp, body, what: "upload \(digest)") }
    }

    public func pushManifest(_ ref: ImageReference, reference: String, data: Data, mediaType: String, credential: RegistryCredential? = nil) async throws -> String {
        let (scheme, host) = await base(for: ref)
        guard let url = URL(string: "\(scheme)://\(host)/v2/\(ref.path)/manifests/\(reference)") else { throw ImageError.invalid("bad url") }
        let (body, resp) = try await authorized({ auth in
            var q = URLRequest(url: url, timeoutInterval: 60); q.httpMethod = "PUT"
            q.setValue(mediaType, forHTTPHeaderField: "Content-Type")
            q.httpBody = data
            if let auth { q.setValue(auth, forHTTPHeaderField: "Authorization") }
            return q
        }, scheme: scheme, host: host, scope: "repository:\(ref.path):pull,push", credential: credential, send: { try await self.transport.data($0) })
        guard resp.statusCode == 201 || resp.statusCode == 200 else { throw fail(resp, body, what: "push manifest") }
        return resp.value(forHTTPHeaderField: "Docker-Content-Digest") ?? Digest.sha256(data)
    }
}
