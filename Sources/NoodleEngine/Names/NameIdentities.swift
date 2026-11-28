import Foundation
import NoodleCore
import Security

/// Per-name certificates for the HTTPS listener: one leaf per host, issued by the local CA on first use and kept in
/// memory for a day, so a long-running daemon picks up the leaf the CA reissues before it expires.
/// Issuing runs openssl, so callers must be off any event loop; one issuance runs at a time.
final class NameIdentities: @unchecked Sendable {
    private let ca: LocalCA
    private let lock = NSLock()
    private var cache: [String: (identity: SecIdentity, loaded: Date)] = [:]
    private let now: @Sendable () -> Date
    /// Well inside the leaf lifetime: a reload only reissues once the file on disk is near expiry.
    static let reloadAfter: TimeInterval = 86_400

    init(ca: LocalCA, now: @escaping @Sendable () -> Date = Date.init) { self.ca = ca; self.now = now }

    /// Create both authorities under the same lock issuance uses, so two creators never race.
    func prepare() {
        lock.lock(); defer { lock.unlock() }
        try? ca.ensureCA()
        try? ca.authority(for: LocalNameDomain.brandedSuffix).ensureCA()
    }

    /// Await a ready CA file before advertising a dev registration's certificate path.
    func prepare(host: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                self.lock.lock(); defer { self.lock.unlock() }
                do {
                    try self.ca.authority(for: host).ensureCA()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func identity(for host: String) throws -> SecIdentity {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[host], now().timeIntervalSince(hit.loaded) < Self.reloadAfter { return hit.identity }
        let bundle = try ca.authority(for: host).identityBundle(host: host)
        var items: CFArray?
        let rc = SecPKCS12Import(bundle as CFData, [kSecImportExportPassphrase: LocalCA.bundlePassphrase, kSecImportToMemoryOnly: true] as CFDictionary, &items)
        guard rc == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let any = first[kSecImportItemIdentity as String] else { throw EngineError.internalError("certificate for \(host) could not be loaded (\(rc))") }
        let id = any as! SecIdentity // swiftlint:disable:this force_cast
        cache[host] = (id, now())
        return id
    }
}
