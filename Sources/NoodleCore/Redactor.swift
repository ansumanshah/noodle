import Foundation

/// Scrubs secrets and personal paths from text before it leaves a log file.
/// Secrets become `[redacted]`; optional identity pseudonyms are salted per instance.
/// Reuse one instance across every file in a diagnostics bundle.
public struct Redactor: Sendable {
    public static let mark = "[redacted]"

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    private let rules: [Rule]
    private let homePath: String?
    private let identities: [String]
    private let anonymizeIdentities: Bool
    private let salt: String

    /// Names that mark an environment variable or JSON key as secret.
    static let secretWords = "KEY|PASS|TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|APIKEY|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|CREDS|AUTH|COOKIE|SESSION|BEARER"

    /// - Parameter home: the current user's home directory; replaced with `~`.
    public init(home: String? = NSHomeDirectory(), identities: [String] = [], anonymizeIdentities: Bool = false) {
        self.anonymizeIdentities = anonymizeIdentities
        salt = UUID().uuidString
        var values = identities
        if anonymizeIdentities {
            values += [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName]
            if let home { values.append(URL(fileURLWithPath: home).lastPathComponent) }
        }
        self.identities = Set(values.filter { !$0.isEmpty }).sorted { $0.count > $1.count }
        homePath = (home?.count ?? 0) > 1 ? home : nil
        func rule(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> Rule {
            // Patterns are literals in this file.
            // swiftlint:disable:next force_try
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template)
        }
        let m = Redactor.mark
        let words = Redactor.secretWords
        rules = [
            // Remove whole PEM blocks before assignment rules can consume their header.
            rule(#"-----BEGIN ([A-Z0-9 ]+)-----[\s\S]*?(?:-----END \1-----|\z)"#, "[redacted PEM]"),
            // Authorization headers and bearer tokens.
            // Any scheme (Bearer, Basic, Digest, AWS4-...): the rest of the line is the credential.
            rule(#"(?i)\b(authorization["']?\s*[:=]\s*["']?)[^\r\n]{6,}"#, "$1\(m)"),
            // Cookie, Set-Cookie and X-Api-Key headers carry whole-line secrets.
            rule(#"(?i)\b((?:set-)?cookie["']?\s*:\s*)[^\r\n]+"#, "$1\(m)"),
            rule(#"(?i)\b(x-api-key["']?\s*[:=]\s*["']?)[^\s"']+"#, "$1\(m)"),
            rule(#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{8,}"#, "$1 \(m)"),
            // Credentials embedded in URLs: scheme://user:pass@host.
            rule(#"(?i)\b([a-z][a-z0-9+.\-]*://)[^\s/@"']+@"#, "$1\(m)@"),
            // JSON keys: "password": "...", "auth": "...", "identitytoken": "...".
            rule(#"(?i)("[A-Za-z0-9_\-]*(?:\#(words)|identitytoken|registrytoken)[A-Za-z0-9_\-]*"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"\(m)\""),
            // CLI flags: --password x, --password=x, --token x, --auth x.
            rule(#"(?i)(--(?:[a-z\-]*(?:password|passwd|token|secret|auth|api-key|credential)[a-z\-]*)(?:=|\s+))(?!--)\S+"#, "$1\(m)"),
            // Environment style assignments: NAME=value where NAME looks secret.
            rule(#"(?i)\b([A-Za-z0-9_]*(?:\#(words))[A-Za-z0-9_]*\s*=\s*)("[^"]*"|'[^']*'|\S+)"#, "$1\(m)"),
            // YAML/log style: password: value, api_key: value.
            // The secret word must be a whole key segment (split on _ - .), so passed, bypass and max_tokens stay readable.
            rule(#"(?i)(?<![A-Za-z0-9])((?:[A-Za-z0-9]+[_\-.])*(?:pass|passwd|password|passphrase|secret|token|api[_\-]?key)(?:[_\-.][A-Za-z0-9]+)*[ \t]*:[ \t]+)(?!\[redacted\])("[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+)"#, "$1\(m)"),
            // Registry and cloud account identifiers are private even when they are not credentials.
            rule(#"(?i)("(?:username|user|email|client_email|client_id|tenant_id|subscription_id|accountname|private_key_id)"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"\(m)\""),
            rule(#"(?i)\b((?:AccountName|AccountKey|SharedAccessSignature)\s*=\s*)[^;\s]+"#, "$1\(m)"),
            // Well-known token shapes, anywhere in a line.
            rule(#"\bAIza[A-Za-z0-9_\-]{30,}"#, m),
            rule(#"\bya29\.[A-Za-z0-9_\-]{20,}"#, m),
            rule(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#, m),
            rule(#"\bhf_[A-Za-z0-9]{20,}"#, m),
            rule(#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, m),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, m),
            rule(#"\bglpat-[A-Za-z0-9_\-]{16,}"#, m),
            rule(#"\bnpm_[A-Za-z0-9]{20,}"#, m),
            rule(#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#, m),
            rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, m),
            rule(#"\bxapp-[A-Za-z0-9\-]{16,}"#, m),
            rule(#"(?i)([?&](?:sig|signature|token|key)=)[^&\s"']+"#, "$1\(m)"),
            rule(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, m),
            rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"#, m),
            // Tunnel credentials are base64 JSON rather than a three-part JWT.
            rule(#"\beyJhIjoi[A-Za-z0-9+/=_\-]{40,}"#, m),
            // Any other user's home folder.
            rule(#"/Users/[^/\s"':]+"#, "/Users/<user>"),
        ]
    }

    public func redact(_ text: String) -> String {
        var s = text
        if let home = homePath { s = s.replacingOccurrences(of: home, with: "~") }
        for r in rules {
            let range = NSRange(s.startIndex..., in: s)
            s = r.regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: r.template)
        }
        guard anonymizeIdentities else { return s }
        if !identities.isEmpty {
            s = replace(s, pattern: "(?<![A-Za-z0-9_])(?:" + identities.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![A-Za-z0-9_])")
        }
        s = replace(s, pattern: #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#)
        s = replace(s, pattern: #"(?i)(?:\b(?:username|account|email)[=: ]+["']?|(?:--username|-u)\s+)([^"'\s,;]+)"#, capture: 1)
        // Contextual names cover text from crash reports and logs even if state was deleted.
        s = replace(s, pattern: #"(?i)(?:"(?:image|name|hostname|com\.docker\.compose\.project)"\s*:\s*"|\b(?:image|container|project|hostname)[=: ]+)([^"\s,;]+)"#, capture: 1)
        s = replace(s, pattern: #"(?i)\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*\b"#)
        s = replace(s, pattern: #"(?i)\b[a-z][a-z0-9+.\-]*://(?:\[redacted\]@)?([a-z][a-z0-9\-]*)(?=[:/\s]|$)"#, capture: 1)
        // IPv6 including compressed, mapped IPv4 and scoped addresses.
        s = replace(s, pattern: #"(?i)(?<![\w:])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.]*(?:%[a-z0-9]+)?"#)
        s = replace(s, pattern: #"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])"#, preserveNoodleIP: true)
        return s
    }

    private func pseudonym(_ value: String) -> String {
        "[identity-" + String(Digest.sha256Hex(Data((salt + value).utf8)).prefix(16)) + "]"
    }

    private func replace(_ text: String, pattern: String, capture: Int = 0, preserveNoodleIP: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: capture), in: result) else { continue }
            let value = String(result[range])
            if value.hasPrefix("[identity-") { continue }
            if preserveNoodleIP, value.hasPrefix("172.18.") || value.hasPrefix("192.168.64.") { continue }
            result.replaceSubrange(range, with: pseudonym(value))
        }
        return result
    }
}
