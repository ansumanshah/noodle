import Foundation

extension LocalCA {
    /// The bundle's passphrase only satisfies the PKCS#12 format. The file is the protection: mode 0600 in a 0700 folder.
    public static let bundlePassphrase = "noodle"
    static let leafLifetime: TimeInterval = 60 * 86_400

    var leafDirectory: URL { directory.appendingPathComponent("leaf", isDirectory: true) }

    /// PKCS#12 holding a certificate for one host in this authority's namespace and its key. Cached on disk and
    /// reissued once it is 60 days old (leaves are valid for 90). Blocking: it runs openssl on a cache miss.
    public func identityBundle(host: String) throws -> Data {
        guard supports(host) else {
            throw Failure.tool("certificate host must be a valid \(domain.rawValue) name")
        }
        let fm = FileManager.default
        try ensureCA()
        try fm.createDirectory(at: leafDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = leafDirectory.appendingPathComponent("\(host).p12")
        if let made = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(made) < Self.leafLifetime, let data = try? Data(contentsOf: file) { return data }
        let work = leafDirectory.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let leaf = try issue(hosts: [host], into: work)
        let out = work.appendingPathComponent("b.p12")
        try Self.run([Self.openssl, "pkcs12", "-export", "-inkey", leaf.key.path, "-in", leaf.cert.path, "-certfile", certificate.path,
                      "-passout", "pass:\(Self.bundlePassphrase)", "-out", out.path])
        chmod(out.path, 0o600)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: out, to: file)
        return try Data(contentsOf: file)
    }
}
