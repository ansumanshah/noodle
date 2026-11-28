import Foundation

/// Separate name-constrained authorities for localhost and noodle.local HTTPS. The original localhost authority
/// stays under `$NOODLE_HOME/tls`; noodle.local has its own keys below `tls/noodle-local`. Trust is an explicit step.
public struct LocalCA: Sendable {
    public enum Domain: String, Sendable {
        case localhost
        case noodleLocal = "noodle.local"
    }

    public enum Failure: Error, CustomStringConvertible {
        case tool(String)
        public var description: String { if case .tool(let s) = self { return s } else { return "" } }
    }

    public static let commonName = "Noodle Local Certificate Authority"
    public static let openssl = "/usr/bin/openssl"
    public static let security = "/usr/bin/security"
    private let legacyDirectory: URL
    public let domain: Domain
    public let directory: URL
    public var certificate: URL { directory.appendingPathComponent("ca.pem") }
    var key: URL { directory.appendingPathComponent("ca.key") }

    public init(paths: NoodlePaths, domain: Domain = .localhost) {
        self.init(directory: paths.root.appendingPathComponent("tls", isDirectory: true), domain: domain)
    }

    /// `directory` is the original localhost CA directory; other authorities use isolated children of it.
    public init(directory: URL, domain: Domain = .localhost) {
        self.legacyDirectory = directory
        self.domain = domain
        self.directory = domain == .localhost ? directory : directory.appendingPathComponent("noodle-local", isDirectory: true)
    }

    /// Select the authority without generating keys, modifying existing certificates, or changing trust.
    public func authority(for host: String) throws -> LocalCA {
        guard LocalNameDomain.isSupported(host) else { throw Failure.tool("unsupported local hostname: \(host)") }
        let selected: Domain = host == "localhost" || host.hasSuffix(".localhost") ? .localhost : .noodleLocal
        return LocalCA(directory: legacyDirectory, domain: selected)
    }

    func supports(_ host: String) -> Bool {
        LocalNameDomain.isSupported(host) && (host == domain.rawValue || host.hasSuffix(".\(domain.rawValue)"))
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: certificate.path) }

    // MARK: - Config text

    public static let caConfig = configuration(domain: .localhost)

    static func configuration(domain: Domain) -> String {
        let name = domain == .localhost ? commonName : "Noodle Local Certificate Authority (noodle.local)"
        return """
    [req]
    distinguished_name=dn
    prompt=no
    x509_extensions=ext
    [dn]
    CN=\(name)
    O=Noodle
    [ext]
    basicConstraints=critical,CA:TRUE,pathlen:0
    keyUsage=critical,keyCertSign,cRLSign
    nameConstraints=critical,permitted;DNS:\(domain.rawValue),excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
    subjectKeyIdentifier=hash
    """
    }

    static func leafConfig(hosts: [String]) -> String {
        let alt = hosts.enumerated().map { "DNS.\($0.offset + 1)=\($0.element)" }.joined(separator: "\n")
        return """
        [req]
        distinguished_name=dn
        prompt=no
        [dn]
        CN=\(hosts.first ?? "localhost")
        [ext]
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        authorityKeyIdentifier=keyid
        subjectAltName=@alt
        [alt]
        \(alt)
        """
    }

    // MARK: - Trust commands (argv only; nothing here runs them)

    /// `security add-trusted-cert` into the user's login keychain, for SSL only. Prompts the user for a password.
    public static func trustCommand(certificate: URL, keychain: String) -> [String] {
        [security, "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, certificate.path]
    }

    public static func untrustCommand(certificate: URL) -> [String] {
        [security, "remove-trusted-cert", certificate.path]
    }

    public static var loginKeychain: String { ("~/Library/Keychains/login.keychain-db" as NSString).expandingTildeInPath }

    // MARK: - Generation

    /// Create the CA if missing, or renew it when it expires within 30 days. Never replaces a key whose certificate is missing.
    /// A renewed authority is a new certificate: it has to be trusted again (`noodle names trust`), and cached leaves are dropped.
    public func ensureCA() throws {
        let fm = FileManager.default
        let renewing = exists
        if renewing, (try? Self.run([Self.openssl, "x509", "-checkend", "2592000", "-noout", "-in", certificate.path])) != nil { return }
        guard renewing || !fm.fileExists(atPath: key.path) else {
            throw Failure.tool("CA certificate is missing but its key exists at \(key.path); refusing to replace the key")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let work = directory.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let cnf = work.appendingPathComponent("ca.cnf"), newKey = work.appendingPathComponent("ca.key"), newCert = work.appendingPathComponent("ca.pem")
        try Self.configuration(domain: domain).write(to: cnf, atomically: true, encoding: .utf8)
        try Self.run([Self.openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-sha256",
                      "-days", "825", "-config", cnf.path, "-keyout", newKey.path, "-out", newCert.path])
        chmod(newKey.path, 0o600)
        if renewing {
            try? fm.removeItem(at: leafDirectory)
            try? fm.removeItem(at: directory.appendingPathComponent("ca.srl"))
        }
        // Key first, certificate last: a crash in between never leaves a certificate without its key.
        // shortcut: a crash between the two renames of a renewal leaves the new key with the old certificate; delete ca.pem and ca.key to recover.
        _ = try fm.replaceItemAt(key, withItemAt: newKey)
        _ = try fm.replaceItemAt(certificate, withItemAt: newCert)
    }

    /// Sign a server certificate only when every host belongs to this authority's namespace.
    public func issue(hosts: [String], into out: URL) throws -> (cert: URL, key: URL) {
        guard !hosts.isEmpty, hosts.allSatisfy({ supports($0) }) else {
            throw Failure.tool("all certificate hosts must be valid \(domain.rawValue) names")
        }
        try ensureCA()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cnf = out.appendingPathComponent("leaf.cnf"), csr = out.appendingPathComponent("leaf.csr")
        let cert = out.appendingPathComponent("leaf.pem"), leafKey = out.appendingPathComponent("leaf.key")
        try Self.leafConfig(hosts: hosts).write(to: cnf, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cnf); try? FileManager.default.removeItem(at: csr) }
        // RSA, not EC: macOS cannot import an EC key from a PKCS#12 bundle in memory (it aborts), and the server needs that.
        try Self.run([Self.openssl, "req", "-new", "-newkey", "rsa:2048", "-nodes",
                      "-config", cnf.path, "-keyout", leafKey.path, "-out", csr.path])
        chmod(leafKey.path, 0o600)
        try Self.run([Self.openssl, "x509", "-req", "-in", csr.path, "-CA", certificate.path, "-CAkey", key.path, "-CAcreateserial",
                      "-CAserial", directory.appendingPathComponent("ca.srl").path, "-sha256", "-days", "90", "-extfile", cnf.path,
                      "-extensions", "ext", "-out", cert.path])
        return (cert, leafKey)
    }

    /// True when openssl accepts `leaf` as issued by this CA.
    public func verifies(_ leaf: URL) -> Bool {
        (try? Self.run([Self.openssl, "verify", "-CAfile", certificate.path, leaf.path])) != nil
    }

    @discardableResult
    static func run(_ argv: [String]) throws -> String {
        let (status, text) = try runCapturing(URL(fileURLWithPath: argv[0]), Array(argv.dropFirst()))
        guard status == 0 else { throw Failure.tool("\(URL(fileURLWithPath: argv[0]).lastPathComponent) failed: \(text.suffix(300))") }
        return text
    }
}
