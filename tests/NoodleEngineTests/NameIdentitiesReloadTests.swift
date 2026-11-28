import Foundation
import Security
import Synchronization
import Testing
@testable import NoodleCore
@testable import NoodleEngine

@Suite struct NameIdentitiesReloadTests {
    private static func der(_ id: SecIdentity) -> Data? {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(id, &cert)
        return cert.map { SecCertificateCopyData($0) as Data }
    }

    /// A cached HTTPS identity is reloaded after a day, so the daemon never serves a leaf past its lifetime.
    @Test(.tags(.slow)) func cachedIdentityReloadsAfterADay() throws {
        let dir = try scratchDir("names-ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let ca = LocalCA(directory: dir.appendingPathComponent("tls"))
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let ids = NameIdentities(ca: ca, now: { clock.withLock { $0 } })
        let host = "web.localhost"
        let first = Self.der(try ids.identity(for: host))
        // Stand-in for the CA reissuing the leaf on disk.
        try FileManager.default.removeItem(at: try ca.authority(for: host).leafDirectory)
        clock.withLock { $0 += NameIdentities.reloadAfter - 60 }
        #expect(Self.der(try ids.identity(for: host)) == first)
        clock.withLock { $0 += 120 }
        let second = Self.der(try ids.identity(for: host))
        #expect(second != nil && second != first)
    }
}
