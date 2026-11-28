import Foundation
import CryptoKit

/// One signed release description. A feed file holds exactly one architecture, so
/// `<base>/arm64/appcast.json` and `<base>/x86_64/appcast.json` can never be swapped for each other:
/// the architecture is inside the signed message and checked against the running machine.
public struct UpdateFeed: Codable, Sendable, Equatable {
    public var version: String
    public var build: Int
    public var arch: String
    public var minimumSystem: String
    /// Absolute, or relative to the feed URL.
    public var url: String
    public var length: Int
    public var sha256: String
    /// Base64 Ed25519 signature over `signedMessage`.
    public var signature: String
    public var notes: String?

    public init(version: String, build: Int, arch: String, minimumSystem: String = "26.0",
                url: String, length: Int, sha256: String, signature: String = "", notes: String? = nil) {
        self.version = version; self.build = build; self.arch = arch; self.minimumSystem = minimumSystem
        self.url = url; self.length = length; self.sha256 = sha256; self.signature = signature; self.notes = notes
    }

    /// What the release key signs. It binds the artifact hash to version, build and architecture, so a
    /// valid artifact cannot be replayed as another version or architecture. Keep in sync with scripts/update-sign.swift.
    public var signedMessage: Data {
        Data("noodle-update-v1\n\(version)\n\(build)\n\(arch)\n\(minimumSystem)\n\(length)\n\(sha256)\n".utf8)
    }

    public static func feedURL(base: String, arch: String) -> URL? {
        guard var comps = URLComponents(string: base), comps.scheme != nil else { return nil }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/\(arch)/appcast.json"
        return comps.url
    }

    public func artifactURL(relativeTo feed: URL) -> URL? { URL(string: url, relativeTo: feed)?.absoluteURL }

    public static var currentArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case notConfigured, badFeed(String), badSignature, wrongArch(String), notNewer, systemTooOld(String)
    case sizeMismatch(Int, Int), hashMismatch, tooLarge, badBundle(String), signatureCheckFailed(String)
    case noStagedUpdate, installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Updates are not configured in this build."
        case .badFeed(let m): "The update feed is not valid: \(m)"
        case .badSignature: "The update signature does not match the release key."
        case .wrongArch(let a): "The update is for \(a), not this Mac."
        case .notNewer: "This is the newest version."
        case .systemTooOld(let v): "The update needs macOS \(v) or later."
        case .sizeMismatch(let want, let got): "The download is \(got) bytes, expected \(want)."
        case .hashMismatch: "The download does not match its checksum and was discarded."
        case .tooLarge: "The update is larger than the allowed size."
        case .badBundle(let m): "The downloaded app was rejected: \(m)"
        case .signatureCheckFailed(let m): "The downloaded app failed its code signature check: \(m)"
        case .noStagedUpdate: "No update is staged."
        case .installFailed(let m): "Install failed: \(m)"
        }
    }
}

public enum UpdateVerifier {
    public static let maxFeedBytes = 64 * 1024
    public static let maxArtifactBytes = 1 << 31

    public static func decode(_ data: Data) throws -> UpdateFeed {
        guard data.count <= maxFeedBytes else { throw UpdateError.badFeed("feed too large") }
        do { return try JSONDecoder().decode(UpdateFeed.self, from: data) }
        catch { throw UpdateError.badFeed("cannot decode") }
    }

    public static func verifySignature(_ feed: UpdateFeed, publicKeyBase64: String) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw UpdateError.notConfigured }
        guard let sig = Data(base64Encoded: feed.signature),
              key.isValidSignature(sig, for: feed.signedMessage) else { throw UpdateError.badSignature }
    }

    /// Everything decided from the feed alone, before any download.
    public static func accept(_ feed: UpdateFeed, publicKeyBase64: String, currentBuild: Int,
                              arch: String = UpdateFeed.currentArch,
                              systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        try verifySignature(feed, publicKeyBase64: publicKeyBase64)
        guard feed.arch == arch else { throw UpdateError.wrongArch(feed.arch) }
        guard Digest.isValid(feed.sha256), feed.length > 0, feed.length <= maxArtifactBytes else { throw UpdateError.badFeed("artifact fields") }
        guard feed.build > currentBuild else { throw UpdateError.notNewer }
        var need = feed.minimumSystem.split(separator: ".").compactMap { Int($0) }
        while need.count < 3 { need.append(0) }
        let have = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
        if have.lexicographicallyPrecedes(need) { throw UpdateError.systemTooOld(feed.minimumSystem) }
    }
}
