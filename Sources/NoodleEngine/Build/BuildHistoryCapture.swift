import Foundation
import NoodleCore

actor BuildHistoryCapture {
    private var record: BuildHistoryRecord
    private var text = ""
    private var truncated = false
    private var linePrefix = ""
    private var steps = Set<String>()
    private var cached = Set<String>()
    private let secrets: [String]
    private let tagSecrets: [String]
    private let root: URL
    private static let logLimit = 2 * 1024 * 1024

    init(tags: [String], args: [String: String], contextSize: Int64, root: URL) {
        record = BuildHistoryRecord(tags: tags, contextSize: contextSize)
        // Persist no argument values, including ones whose names do not look secret.
        secrets = Array(Set(args.values.flatMap { value in
            [value] + value.components(separatedBy: .newlines)
        }.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
        let words = ["token", "secret", "password", "passwd", "passphrase", "key", "credential", "auth", "cookie", "session"]
        tagSecrets = args.filter { key, _ in words.contains { key.lowercased().contains($0) } }
            .values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        self.root = root
    }

    func begin() async throws {
        record.tags = record.tags.map { tag in
            var safe = tag
            for secret in tagSecrets { safe = safe.replacingOccurrences(of: secret, with: Redactor.mark) }
            return Redactor().redact(safe)
        }
        try await BuildHistoryWriter.shared.write(record, root: root)
    }

    private func countStep() {
        let parts = linePrefix.split(separator: " ", maxSplits: 2)
        guard let id = parts.first, id.first == "#", Int(id.dropFirst()) != nil else { return }
        steps.insert(String(id))
        if parts.count > 1, parts[1] == "CACHED" { cached.insert(String(id)) }
    }

    func append(_ message: String) {
        // Count steps even after the log cap, retaining only a short line prefix.
        let pieces = message.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() {
            linePrefix += piece.prefix(max(0, 256 - linePrefix.count))
            if index < pieces.count - 1 { countStep(); linePrefix = "" }
        }
        guard !truncated else { return }
        let remaining = Self.logLimit - text.utf8.count
        if message.utf8.count > remaining {
            text += String(decoding: message.utf8.prefix(remaining), as: UTF8.self)
            truncated = true
        } else { text += message }
    }

    private func scrub(_ value: String) -> String {
        var result = value
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: Redactor.mark) }
        return Redactor().redact(result)
    }

    func finish(error: String?, cancelled: Bool) async throws {
        record.endedAt = Date()
        record.duration = max(0, record.endedAt!.timeIntervalSince(record.startedAt))
        record.status = cancelled ? "cancelled" : (error == nil ? "success" : "failed")
        // Drop a potentially partial secret at the capture boundary before redaction.
        if truncated { text = String(text.dropLast(secrets.map(\.count).max() ?? 0)) }
        countStep()
        let sanitized = scrub(text)
        record.error = error.map { message in
            // The builder's last-log suffix can start midway through a secret. Use
            // the captured, scrubbed log instead of persisting that raw suffix.
            let safe = message.hasPrefix("BuildKit failed\n")
                ? "BuildKit failed\n" + String(sanitized.suffix(4096)) : scrub(message)
            return String(safe.prefix(4096))
        }
        record.totalSteps = steps.count
        record.cachedSteps = cached.count
        record.log = String(decoding: sanitized.utf8.prefix(Self.logLimit), as: UTF8.self)
        // UTF-8 replacement at the byte boundary can add two bytes.
        while record.log.utf8.count > Self.logLimit { record.log.removeLast() }
        try await BuildHistoryWriter.shared.write(record, root: root)
    }
}
