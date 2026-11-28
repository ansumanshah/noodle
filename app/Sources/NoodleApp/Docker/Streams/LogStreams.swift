import Foundation

// MARK: - Parsing helpers

struct LineSplitter {
    private var buf = Data()
    mutating func feed(_ d: Data) -> [Data] {
        buf.append(d)
        var out: [Data] = []
        while let i = buf.firstIndex(of: 10) {
            let line = buf[buf.startIndex..<i]
            if !line.isEmpty { out.append(Data(line)) }
            buf.removeSubrange(buf.startIndex...i)
        }
        return out
    }
}

enum LogLevel: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case debug, info, warn, error
    var id: Int { rawValue }
    var label: String { ["Debug", "Info", "Warning", "Error"][rawValue] }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    static func detect(_ line: String, stderr: Bool) -> LogLevel {
        let head = line.prefix(160).lowercased()
        if head.contains("error") || head.contains("fatal") || head.contains("panic") || head.contains("[err") || head.contains("level=err") { return .error }
        if head.contains("warn") { return .warn }
        if head.contains("debug") || head.contains("trace") { return .debug }
        if head.contains("info") { return .info }
        return stderr ? .warn : .info
    }
}

struct LogEntry: Identifiable, Hashable, Sendable {
    var id: Int = 0
    var stderr: Bool
    var time: Date?
    var text: String
    var level: LogLevel
}

/// Splits Docker's multiplexed stream (8-byte header per frame) or a raw tty stream into lines.
struct LogDemuxer {
    let tty: Bool
    let timestamps: Bool
    private var buf = Data()
    private var partial: [Bool: String] = [:]
    static let maxPartialBytes = 64 * 1024
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    init(tty: Bool, timestamps: Bool = true) { self.tty = tty; self.timestamps = timestamps }

    mutating func feed(_ d: Data) -> [LogEntry] {
        buf.append(d)
        var out: [LogEntry] = []
        if tty {
            // A read can end inside a multibyte character: hold those bytes for the next read.
            let keep = Self.incompleteUTF8Tail(buf)
            out += lines(from: Data(buf.dropLast(keep)), stderr: false)
            buf = Data(buf.suffix(keep))
            return out
        }
        while buf.count >= 8 {
            let s = buf.startIndex
            let size = Int(buf[s + 4]) << 24 | Int(buf[s + 5]) << 16 | Int(buf[s + 6]) << 8 | Int(buf[s + 7])
            guard buf.count >= 8 + size else { break }
            let stream = buf[s]
            let payload = buf[(s + 8)..<(s + 8 + size)]
            buf.removeSubrange(s..<(s + 8 + size))
            out += lines(from: Data(payload), stderr: stream == 2)
        }
        return out
    }

    mutating func flush() -> [LogEntry] {
        var out: [LogEntry] = []
        if tty, !buf.isEmpty { partial[false, default: ""] += String(decoding: buf, as: UTF8.self); buf.removeAll() }
        for (err, text) in partial where !text.isEmpty { out.append(make(text, stderr: err)) }
        partial.removeAll()
        return out
    }

    /// Bytes at the end of `d` that start a UTF-8 sequence the data does not finish (0 to 3).
    static func incompleteUTF8Tail(_ d: Data) -> Int {
        guard !d.isEmpty else { return 0 }
        for back in 1...min(3, d.count) {
            let byte = d[d.endIndex - back]
            guard byte & 0xC0 == 0x80 else {
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return length > back ? back : 0
            }
        }
        return 0
    }

    private mutating func lines(from data: Data, stderr: Bool) -> [LogEntry] {
        var text = (partial[stderr] ?? "") + String(decoding: data, as: UTF8.self)
        partial[stderr] = nil
        var out: [LogEntry] = []
        while let nl = text.firstIndex(of: "\n") {
            let line = String(text[text.startIndex..<nl]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            text.removeSubrange(text.startIndex...nl)
            out.append(make(line, stderr: stderr))
        }
        // An endless line must not grow without bound: past the cap it is emitted as its own entry.
        if text.utf8.count > Self.maxPartialBytes { out.append(make(text, stderr: stderr)) }
        else if !text.isEmpty { partial[stderr] = text }
        return out
    }

    private func make(_ line: String, stderr: Bool) -> LogEntry {
        var body = line
        var time: Date?
        if timestamps, let sp = line.firstIndex(of: " "), line.first?.isNumber == true, sp < line.index(line.startIndex, offsetBy: 40, limitedBy: line.endIndex) ?? line.endIndex {
            time = Self.iso.date(from: String(line[..<sp]))
            if time != nil { body = String(line[line.index(after: sp)...]) }
        }
        return LogEntry(stderr: stderr, time: time, text: body, level: LogLevel.detect(body, stderr: stderr))
    }
}
