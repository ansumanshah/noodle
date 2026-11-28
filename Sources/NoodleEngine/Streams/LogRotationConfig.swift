import Foundation

/// Docker's `--log-driver` / `--log-opt` rules for the drivers Noodle can serve, reduced to what the guest needs.
public struct LogRotationConfig: Equatable, Sendable {
    /// Bytes per file; 0 = never rotate.
    public var maxSize: Int64 = 0
    /// Files kept, the current one included.
    public var maxFile = 1

    static let knownDrivers: Set<String> = [
        "json-file", "local", "none", "syslog", "journald", "gelf", "fluentd", "awslogs", "splunk", "etwlogs", "gcplogs", "logentries"
    ]
    static let allowedOptions: [String: Set<String>] = [
        "json-file": ["max-file", "max-size", "labels", "labels-regex", "env", "env-regex", "compress", "tag"],
        "local": ["max-file", "max-size", "compress"],
        "none": []
    ]
    /// `local` rotates by default.
    static let localDefaults = LogRotationConfig(maxSize: 20_000_000, maxFile: 5)

    /// Throws `EngineError.invalid` (HTTP 400) with Docker's wording.
    public static func validate(_ cfg: LogConfig) throws -> LogRotationConfig {
        let driver = cfg.Type.isEmpty ? "json-file" : cfg.Type
        guard knownDrivers.contains(driver) else {
            throw EngineError.invalid("logger: no log driver named '\(driver)' is registered")
        }
        let opts = cfg.Config ?? [:]
        guard let allowed = allowedOptions[driver] else { return LogRotationConfig() }   // other built-ins: options are theirs
        for key in opts.keys.sorted() where !allowed.contains(key) {
            throw EngineError.invalid("unknown log opt '\(key)' for \(driver) log driver")
        }
        var out = driver == "local" ? localDefaults : LogRotationConfig()
        if let s = opts["max-size"], !s.isEmpty {
            guard let n = parseSize(s) else { throw EngineError.invalid("invalid size: '\(s)'") }
            out.maxSize = n
        }
        if let f = opts["max-file"] {
            guard let n = Int(f) else { throw EngineError.invalid("invalid max-file: \(f)") }
            guard n >= 1 else { throw EngineError.invalid("max-file cannot be less than 1") }
            out.maxFile = n
        }
        return out
    }

    /// go-units FromHumanSize: a number, optional space, optional k/m/g/t/p, optional i, optional b. Decimal multiples.
    static func parseSize(_ text: String) -> Int64? {
        var rest = Substring(text.lowercased())
        if rest.hasSuffix("b") { rest = rest.dropLast() }
        if rest.hasSuffix("i") { rest = rest.dropLast() }
        var mult = 1.0
        if let last = rest.last, let idx = "kmgtp".firstIndex(of: last) {
            mult = pow(1000, Double("kmgtp".distance(from: "kmgtp".startIndex, to: idx) + 1))
            rest = rest.dropLast()
        }
        if rest.hasSuffix(" ") { rest = rest.dropLast() }
        guard !rest.isEmpty, rest.first?.isNumber == true, rest.last?.isNumber == true,
              rest.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), rest.filter({ $0 == "." }).count <= 1,
              let value = Double(rest) else { return nil }
        let bytes = value * mult
        return bytes < 9e18 ? Int64(bytes) : nil
    }
}
