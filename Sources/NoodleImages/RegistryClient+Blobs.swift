import Foundation
import CFNetwork
import NoodleCore

extension RegistryClient {
    // MARK: blobs

    /// Download `digest` into the blob store (skips when present). Progress counts bytes.
    ///
    /// Bytes go to a partial file as they arrive. A dropped connection keeps them, and the next attempt (here, or a
    /// later pull) asks for the rest with `Range`. A server that ignores `Range` (200), a `416`, or bytes that do not
    /// hash to `digest` all restart the blob cleanly. Nothing becomes a blob until the whole file verifies.
    public func fetchBlob(_ ref: ImageReference, digest: String, expectedSize: Int64?, into store: BlobStore, credential: RegistryCredential? = nil,
                          progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        guard Digest.isValid(digest) else { throw ImageError.invalid("bad blob digest \(digest)") }
        if store.has(digest) { return }
        let (scheme, host) = await base(for: ref)
        let scope = "repository:\(ref.path):pull"
        guard let url = URL(string: "\(scheme)://\(host)/v2/\(ref.path)/blobs/\(digest)") else { throw ImageError.invalid("bad blob url") }
        guard let partial = try await openPartialWaiting(store, digest) else { return }
        defer { partial.close() }
        if let expectedSize, partial.size > expectedSize { try partial.reset() }
        if partial.size > 0, partial.size == expectedSize, partial.currentDigest() == digest {
            try partial.promote(into: store, as: digest)       // a finished download that was never installed
            return
        }
        var authRetried = false, transientRetries = 0, restarts = 0
        while true {
            if store.has(digest) { return }                      // another pull finished it first
            let auth = try await authorization(scheme: scheme, host: host, scope: scope, credential: credential)
            var req = URLRequest(url: url, timeoutInterval: 120)
            if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
            if partial.size > 0 { req.setValue("bytes=\(partial.size)-", forHTTPHeaderField: "Range") }
            let stream = BlobStream(partial: partial, expectedSize: expectedSize, progress: progress)
            let before = partial.size
            let resp: HTTPURLResponse
            do { resp = try await transport.stream(req, into: stream) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw error }
                // Connection lost: keep the bytes and try again from there while the transfer is making headway.
                // A drop before any byte arrived gets two quick tries; one that made headway gets up to five.
                let dropped = (error as? URLError)?.code == .networkConnectionLost
                if transientRetries < (partial.size > before ? 5 : dropped ? 2 : 0) { transientRetries += 1; continue }
                throw error
            }
            switch resp.statusCode {
            case 200, 206:
                if stream.restartNeeded {
                    restarts += 1; try partial.reset()
                    guard restarts < 3 else { partial.discard(); throw ImageError.io("registry sent ranges that do not match the request for \(digest)") }
                    continue
                }
                let actual = partial.currentDigest()
                if actual == digest { try partial.promote(into: store, as: digest); return }
                if stream.resumed, restarts < 3 { restarts += 1; try partial.reset(); continue }   // corrupt partial: refetch the whole blob
                partial.discard()
                throw ImageError.digestMismatch(expected: digest, actual: actual)
            case 416:
                // The partial is past the end or the server cannot serve that range: discard it and refetch.
                guard before > 0, restarts < 3 else { partial.discard(); throw fail(resp, stream.errorBody, what: "blob \(digest)") }
                restarts += 1; try partial.reset(); continue
            case 401 where !authRetried:
                authRetried = true; challenges[host] = nil; clearTokens(host: host); continue
            default:
                if resp.statusCode == 404 { partial.discard() }
                throw fail(resp, stream.errorBody, what: "blob \(digest)")
            }
        }
    }

    /// The shared partial for `digest`. While another puller holds it, wait for it to finish (nil: the blob landed) or to
    /// let go. Falls back to a private scratch file only after `stallLimit` with no growth of the shared partial.
    func openPartialWaiting(_ store: BlobStore, _ digest: String, stallLimit: TimeInterval = 600) async throws -> PartialBlob? {
        var lastSize: Int64 = -1, lastGrowth = Date()
        while true {
            if store.has(digest) { return nil }
            if let shared = try store.openSharedPartial(digest) {
                if store.has(digest) { shared.discard(); return nil }
                return shared
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: store.partialURL(digest).path)[.size] as? NSNumber)?.int64Value ?? 0
            if size != lastSize { lastSize = size; lastGrowth = Date() }
            if Date().timeIntervalSince(lastGrowth) > stallLimit { return try store.openPartial(digest) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func blobExists(_ ref: ImageReference, digest: String, credential: RegistryCredential? = nil) async throws -> Bool {
        let (scheme, host) = await base(for: ref)
        guard let url = URL(string: "\(scheme)://\(host)/v2/\(ref.path)/blobs/\(digest)") else { return false }
        let (_, resp) = try await authorized({ auth in
            var q = URLRequest(url: url, timeoutInterval: 30); q.httpMethod = "HEAD"
            if let auth { q.setValue(auth, forHTTPHeaderField: "Authorization") }
            return q
        }, scheme: scheme, host: host, scope: "repository:\(ref.path):pull,push", credential: credential, send: { try await self.transport.data($0) })
        return resp.statusCode == 200
    }
}
