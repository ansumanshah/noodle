import Foundation
import Testing
@testable import NoodleCore

@Suite struct LocalCATests {
    @Test func trustCommandsAreBuiltNotRun() {
        let cert = URL(fileURLWithPath: "/x/ca.pem")
        #expect(LocalCA.trustCommand(certificate: cert, keychain: "/k.keychain-db")
                == ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", "/k.keychain-db", "/x/ca.pem"])
        #expect(LocalCA.untrustCommand(certificate: cert) == ["/usr/bin/security", "remove-trusted-cert", "/x/ca.pem"])
    }

    @Test func issuesLocalhostLeafAndRejectsOtherNames() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let ca = LocalCA(directory: dir.appendingPathComponent("tls"))
        let leaf = try ca.issue(hosts: ["web.localhost", "api.shop.localhost"], into: dir.appendingPathComponent("a"))
        #expect(ca.verifies(leaf.cert))
        #expect(throws: (any Error).self) { try ca.issue(hosts: ["evil.com"], into: dir.appendingPathComponent("b")) }
        // A leaf for a real site, signed with the same key, must fail the name constraint.
        let evil = dir.appendingPathComponent("evil"); try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        let cnf = evil.appendingPathComponent("c.cnf")
        try LocalCA.leafConfig(hosts: ["evil.com"]).write(to: cnf, atomically: true, encoding: .utf8)
        try LocalCA.run([LocalCA.openssl, "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-config", cnf.path, "-keyout", evil.appendingPathComponent("k").path, "-out", evil.appendingPathComponent("r").path])
        try LocalCA.run([LocalCA.openssl, "x509", "-req", "-in", evil.appendingPathComponent("r").path, "-CA", ca.certificate.path, "-CAkey", ca.directory.appendingPathComponent("ca.key").path, "-CAcreateserial", "-CAserial", evil.appendingPathComponent("s").path, "-extfile", cnf.path, "-extensions", "ext", "-out", evil.appendingPathComponent("e.pem").path])
        #expect(!ca.verifies(evil.appendingPathComponent("e.pem")))
    }

    @Test func existingCAIsNeverReplaced() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let ca = LocalCA(directory: dir)
        try ca.ensureCA()
        let before = try Data(contentsOf: ca.certificate)
        let keyBefore = try Data(contentsOf: ca.key)
        try ca.ensureCA()
        #expect(try Data(contentsOf: ca.certificate) == before)
        #expect(try Data(contentsOf: ca.key) == keyBefore)
    }

    @Test func expiringCAIsRenewedAndLeavesStillVerify() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let ca = LocalCA(directory: dir)
        try ca.ensureCA()
        let cnf = dir.appendingPathComponent("short.cnf")
        try LocalCA.configuration(domain: .localhost).write(to: cnf, atomically: true, encoding: .utf8)
        try LocalCA.run([LocalCA.openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-sha256", "-days", "1",
                         "-config", cnf.path, "-keyout", ca.key.path, "-out", ca.certificate.path])
        let expiring = try Data(contentsOf: ca.certificate)
        try ca.ensureCA()
        #expect(try Data(contentsOf: ca.certificate) != expiring)
        _ = try LocalCA.run([LocalCA.openssl, "x509", "-checkend", "2592000", "-noout", "-in", ca.certificate.path])
        let out = dir.appendingPathComponent("leaf")
        let leaf = try ca.issue(hosts: ["localhost"], into: out)
        #expect(ca.verifies(leaf.cert))
    }

    @Test func brandedAuthorityHasSeparateKeysAndPreservesLocalhost() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = LocalCA(directory: dir.appendingPathComponent("tls"))
        let oldLeaf = try legacy.issue(hosts: ["web.localhost"], into: dir.appendingPathComponent("old"))
        let oldCertificate = try Data(contentsOf: legacy.certificate), oldKey = try Data(contentsOf: legacy.key)
        let branded = try legacy.authority(for: "api.noodle.local")
        #expect(branded.domain == .noodleLocal)
        #expect(branded.directory == legacy.directory.appendingPathComponent("noodle-local", isDirectory: true))
        let newLeaf = try branded.issue(hosts: ["noodle.local", "api.noodle.local"], into: dir.appendingPathComponent("new"))
        #expect(branded.verifies(newLeaf.cert))
        #expect(legacy.verifies(oldLeaf.cert))
        #expect(!legacy.verifies(newLeaf.cert))
        #expect(!branded.verifies(oldLeaf.cert))
        #expect(try Data(contentsOf: legacy.certificate) == oldCertificate)
        #expect(try Data(contentsOf: legacy.key) == oldKey)
        #expect(try Data(contentsOf: branded.key) != oldKey)
        #expect(try branded.authority(for: "localhost").certificate == legacy.certificate)
        #expect(try branded.authority(for: "web.noodle.local").certificate == branded.certificate)
        #expect(LocalCA(directory: legacy.directory, domain: .noodleLocal).certificate == branded.certificate)
    }

    @Test func rejectsEveryInvalidSANBeforeWriting() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = LocalCA(directory: dir.appendingPathComponent("tls"))
        let branded = try legacy.authority(for: "noodle.local")
        for hosts in [["web.localhost", "evil.com"], ["web.localhost", "a..localhost"], ["web.localhost", "api.noodle.local"], []] {
            #expect(throws: (any Error).self) { try legacy.issue(hosts: hosts, into: dir.appendingPathComponent("leaf")) }
        }
        for host in ["web.localhost", "evil.com", "../noodle.local", "a..noodle.local", "a-.noodle.local"] {
            #expect(throws: (any Error).self) { try branded.issue(hosts: ["api.noodle.local", host], into: dir.appendingPathComponent("leaf")) }
            #expect(throws: (any Error).self) { try branded.identityBundle(host: host) }
        }
        #expect(throws: (any Error).self) { try legacy.authority(for: "evil.com") }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func orphanedCAKeyIsNeverReplaced() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ca = LocalCA(directory: dir)
        let existing = Data("existing-key-evidence".utf8)
        try existing.write(to: ca.key)
        #expect(throws: (any Error).self) { try ca.ensureCA() }
        #expect(try Data(contentsOf: ca.key) == existing)
        #expect(!ca.exists)
    }

    @Test func eachAuthorityCryptographicallyRejectsOtherNamespaces() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = LocalCA(directory: dir.appendingPathComponent("tls"))
        let branded = try legacy.authority(for: "noodle.local")
        // Bypass the public issuer so OpenSSL, rather than the host validator, must enforce the root constraint.
        for (ca, forbidden) in [(legacy, "api.noodle.local"), (branded, "web.localhost"), (branded, "evil.com")] {
            try ca.ensureCA()
            let work = dir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let cnf = work.appendingPathComponent("leaf.cnf"), csr = work.appendingPathComponent("leaf.csr")
            let key = work.appendingPathComponent("leaf.key"), cert = work.appendingPathComponent("leaf.pem")
            try LocalCA.leafConfig(hosts: [forbidden]).write(to: cnf, atomically: true, encoding: .utf8)
            try LocalCA.run([LocalCA.openssl, "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-config", cnf.path, "-keyout", key.path, "-out", csr.path])
            try LocalCA.run([LocalCA.openssl, "x509", "-req", "-in", csr.path, "-CA", ca.certificate.path, "-CAkey", ca.key.path, "-CAcreateserial", "-CAserial", work.appendingPathComponent("serial").path, "-extfile", cnf.path, "-extensions", "ext", "-out", cert.path])
            #expect(!ca.verifies(cert))
        }
    }

    @Test func brandedIdentityBundleStaysInItsOwnCache() throws {
        let dir = scratchPath("ca"); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = LocalCA(directory: dir.appendingPathComponent("tls"))
        let branded = try legacy.authority(for: "api.noodle.local")
        let first = try branded.identityBundle(host: "api.noodle.local")
        #expect(!first.isEmpty)
        #expect(try branded.identityBundle(host: "api.noodle.local") == first)
        #expect(FileManager.default.fileExists(atPath: branded.leafDirectory.appendingPathComponent("api.noodle.local.p12").path))
        #expect(!legacy.exists)
        #expect(throws: (any Error).self) { try legacy.identityBundle(host: "api.noodle.local") }
    }
}
