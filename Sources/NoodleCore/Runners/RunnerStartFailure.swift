import Foundation

/// The last failed start of one runner kind, kept in the state file so `status` and `doctor` can say why jobs wait.
/// `reason` is the last line of the runner's log with credentials removed.
public struct RunnerStartFailure: Codable, Equatable, Sendable {
    public var kind: RunnerKind
    public var repo: String
    public var at: Date
    public var reason: String?
    /// The log file name inside the runners log folder.
    public var log: String?
    public init(kind: RunnerKind, repo: String, at: Date, reason: String?, log: String?) {
        self.kind = kind; self.repo = repo; self.at = at; self.reason = reason; self.log = log
    }

    public var kindName: String { kind == .linux ? "Linux" : "macOS" }
    public func line(logDirectory: URL) -> String {
        let path = log.map { " Log: \(logDirectory.appendingPathComponent($0).path)" } ?? ""
        return "\(kindName) runners are failing to start: \(reason ?? "no output")." + path
    }

    /// A failure older than this is history, not a current problem.
    public static let lifetime: TimeInterval = 3600

    /// The failures to show, newest first, without the ones that have expired.
    public static func active(_ failures: [String: RunnerStartFailure]?, now: Date = Date()) -> [RunnerStartFailure] {
        (failures ?? [:]).values.filter { $0.isActive(now: now) }.sorted { $0.at > $1.at }
    }

    /// The wall clock can step: a failure a few minutes in the future still counts, one far in the future is
    /// expired rather than kept forever.
    public func isActive(now: Date = Date()) -> Bool { (-300...Self.lifetime).contains(now.timeIntervalSince(at)) }
}

extension RunnerStartFailure {
    private static let scrubbers: [(NSRegularExpression, String)] = ([
        (#"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@"']+@"#, "$1"),  // credentials in a URL, dropped rather than marked
        (#"(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+"#, "[hidden]"),  // GitHub tokens
        (#"eyJ[A-Za-z0-9_-]{8,}"#, "[hidden]"),  // the start of a JWT part
        // Standard Base64 holds slashes: a run of 32 or more with a 16-character stretch between them. Paths keep their
        // short components, so they stay readable.
        (#"(?<![A-Za-z0-9+/=])(?=[A-Za-z0-9+/=]{32,})[A-Za-z0-9+/=]*[A-Za-z0-9+=]{16,}[A-Za-z0-9+/=]*"#, "[hidden]"),
        (#"[A-Za-z0-9+=_-]{32,}"#, "[hidden]")  // URL-safe encoded configs, digests, keys
    ] as [(String, String)]).compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    private static let redactor = Redactor(home: nil)

    /// One short line from a log with credentials replaced, cut to 200 characters.
    public static func reason(fromLogLine line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for (regex, template) in scrubbers {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        text = redactor.redact(text)  // Bearer, password=, secret=, other token shapes
        guard !text.isEmpty else { return nil }
        return text.count > 200 ? String(text.prefix(200)) + "..." : text
    }

    /// The last non-empty line of a log, skipping the usage hint docker prints after a failed `docker run`.
    public static func lastLine(of log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .last { !$0.allSatisfy(\.isWhitespace) && !$0.hasPrefix("Run 'docker ") }.map(String.init)
    }
}
