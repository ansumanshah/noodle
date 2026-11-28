import Foundation

/// The only DNS namespaces accepted by Noodle's local routing and certificate authorities.
public enum LocalNameDomain {
    public static let brandedSuffix = "noodle.local"

    /// Accept canonical ASCII DNS names only. Keeping validation strict also makes a host safe as a cache filename.
    public static func isSupported(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            let bytes = label.utf8
            guard !bytes.isEmpty, bytes.count <= 63,
                  let first = bytes.first, let last = bytes.last,
                  isAlphaNumeric(first), isAlphaNumeric(last) else { return false }
            return bytes.allSatisfy { isAlphaNumeric($0) || $0 == 45 }
        }) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == brandedSuffix || host.hasSuffix(".\(brandedSuffix)")
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }
}
