import Foundation

/// Where updates come from. Both values live in the app's Info.plist (`NoodleUpdateFeedBase`,
/// `NoodleUpdatePublicKey`), the one place the placeholder feed URL is set.
public struct UpdateConfig: Sendable, Equatable {
    public var feedBase: String
    public var publicKey: String
    public var currentBuild: Int
    public var currentVersion: String
    public var arch: String = UpdateFeed.currentArch

    public init(feedBase: String, publicKey: String, currentBuild: Int, currentVersion: String) {
        self.feedBase = feedBase; self.publicKey = publicKey
        self.currentBuild = currentBuild; self.currentVersion = currentVersion
    }

    /// nil when the plist has no usable feed or key (updates stay off).
    public static func load(infoPlist: URL) -> UpdateConfig? {
        guard let d = NSDictionary(contentsOf: infoPlist) as? [String: Any],
              let base = d["NoodleUpdateFeedBase"] as? String, !base.isEmpty,
              let key = d["NoodleUpdatePublicKey"] as? String, !key.isEmpty,
              let build = (d["CFBundleVersion"] as? String).flatMap(Int.init) else { return nil }
        return UpdateConfig(feedBase: base, publicKey: key, currentBuild: build,
                            currentVersion: d["CFBundleShortVersionString"] as? String ?? "0")
    }
}

/// User choices, kept in `<root>/update/settings.json`. Automatic = check on launch (at most daily)
/// and stage a verified download; nothing is installed without the user choosing Restart.
public struct UpdateSettings: Codable, Sendable, Equatable {
    public var automatic = true
    public var lastCheck: Date?

    public init() {}

    public static func file(_ paths: NoodlePaths) -> URL { UpdateStore.dir(paths).appendingPathComponent("settings.json") }
    public static func load(_ paths: NoodlePaths) -> UpdateSettings {
        (try? JSONDecoder.iso.decode(UpdateSettings.self, from: Data(contentsOf: file(paths)))) ?? UpdateSettings()
    }
    public func save(_ paths: NoodlePaths) throws {
        try FileManager.default.createDirectory(at: UpdateStore.dir(paths), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(self).write(to: Self.file(paths), options: .atomic)
    }
    /// Launch-time rule: no timer, at most one check per day.
    public func shouldCheck(now: Date = Date()) -> Bool {
        automatic && (lastCheck.map { now.timeIntervalSince($0) > 86_400 } ?? true)
    }
}

extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }

public enum UpdateClient {
    /// HTTPS anywhere; HTTP only on loopback. Local files support offline testing.
    public static func isAllowedTransport(_ url: URL) -> Bool {
        switch url.scheme {
        case "https": true
        case "http": isLoopback(url.host)
        case "file": url.host == nil || isLoopback(url.host)
        default: false
        }
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// Fetch and verify the feed. Returns nil when already up to date.
    public static func check(_ config: UpdateConfig, session: URLSession = .shared) async throws -> (feed: UpdateFeed, feedURL: URL)? {
        guard let url = UpdateFeed.feedURL(base: config.feedBase, arch: config.arch), isAllowedTransport(url) else { throw UpdateError.notConfigured }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Noodle/\(config.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (bytes, _) = try await session.bytes(for: request, delegate: UpdateRedirectDelegate())
        var data = Data()
        for try await byte in bytes {      // leaving the loop on overflow cancels the transfer
            guard data.count < UpdateVerifier.maxFeedBytes else { throw UpdateError.badFeed("feed too large") }
            data.append(byte)
        }
        let feed = try UpdateVerifier.decode(data)
        do { try UpdateVerifier.accept(feed, publicKeyBase64: config.publicKey, currentBuild: config.currentBuild, arch: config.arch) }
        catch UpdateError.notNewer { return nil }
        return (feed, url)
    }

    /// Download the artifact and check length and SHA-256 against the signed feed. Returns a file the
    /// caller owns; a mismatch deletes it.
    public static func download(_ feed: UpdateFeed, feedURL: URL, into dir: URL, session: URLSession = .shared) async throws -> URL {
        guard let url = feed.artifactURL(relativeTo: feedURL), isAllowedTransport(url) else { throw UpdateError.badFeed("artifact url") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // a stale or tampered cached body must never stand in for the artifact
        let (bytes, _) = try await session.bytes(for: request, delegate: UpdateRedirectDelegate())
        let dest = dir.appendingPathComponent("Noodle-\(feed.version)-\(feed.arch).zip")
        try? FileManager.default.removeItem(at: dest)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw UpdateError.badFeed("cannot write download") }
        do {
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }
            var written = 0, chunk = Data()
            for try await byte in bytes {      // stop at the signed length instead of filling the disk
                chunk.append(byte)
                if chunk.count == 1 << 16 {
                    written += chunk.count
                    guard written <= feed.length else { throw UpdateError.sizeMismatch(feed.length, written) }
                    try out.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                }
            }
            written += chunk.count
            guard written == feed.length else { throw UpdateError.sizeMismatch(feed.length, written) }
            try out.write(contentsOf: chunk)
            try out.close()
            guard try Digest.sha256Hex(file: dest) == Digest.split(feed.sha256).1 else { throw UpdateError.hashMismatch }
        } catch { try? FileManager.default.removeItem(at: dest); throw error }
        return dest
    }
}

/// Task-scoped so injected sessions and every hop use the same transport restrictions.
final class UpdateRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let scheme = url.scheme, ["https", "http"].contains(scheme),
              UpdateClient.isAllowedTransport(url) else {
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

extension Digest {
    static func sha256Hex(file url: URL) throws -> String { Digest.split(try sha256(file: url)).1 }
}
