import Foundation

/// A deliberately small YAML reader for Kubernetes manifests. Scalars remain strings.
/// Aliases, anchors, tags, merge keys and complex keys are deliberately unsupported.
public enum KubeYAML {
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func quote(_ text: String) -> String {
        // Encoding a String cannot fail.
        // swiftlint:disable:next force_try
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> [[String: Any]] {
        var documents: [[String: Any]] = []
        var lines: [String] = []
        func finish() throws {
            var parser = Parser(lines: lines)
            if let value = try parser.document() { documents.append(value) }
            lines.removeAll(keepingCapacity: true)
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if (line.first != " " && line.first != "\t") && (marker == "---" || marker == "...") {
                try finish()
            } else {
                lines.append(line)
            }
        }
        try finish()
        return documents
    }

    struct Parser {
        let lines: [String]
        var index = 0
        var nesting = 0
        static let maxNesting = 64
        func failure(_ message: String) -> ParseError { ParseError(description: "YAML line \(index + 1): \(message)") }
        func indent(_ line: String) throws -> Int {
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            if prefix.contains("\t") { throw failure("tabs cannot indent YAML") }
            return prefix.count
        }
        mutating func skip() throws {
            while index < lines.count {
                _ = try indent(lines[index])
                if try clean(lines[index]).isEmpty { index += 1 } else { break }
            }
        }
        mutating func document() throws -> [String: Any]? {
            try skip()
            guard index < lines.count else { return nil }
            let level = try indent(lines[index])
            guard level == 0 else { throw failure("document must start at column one") }
            let value = try node(level)
            try skip()
            guard index == lines.count, let map = value as? [String: Any] else { throw failure("expected a mapping document") }
            return map
        }
        func isList(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }
        mutating func node(_ level: Int) throws -> Any {
            nesting += 1; defer { nesting -= 1 }
            guard nesting <= Self.maxNesting else { throw failure("nesting is deeper than \(Self.maxNesting) levels") }
            try skip()
            guard index < lines.count else { return "" }
            return try isList(clean(lines[index])) ? sequence(level) : mapping(level)
        }
        mutating func mapping(_ level: Int) throws -> [String: Any] {
            var result: [String: Any] = [:]
            while true {
                try skip()
                guard index < lines.count else { break }
                let depth = try indent(lines[index])
                let text = try clean(lines[index])
                if depth < level || (depth == level && isList(text)) { break }
                guard depth == level else { throw failure("unexpected indentation") }
                index += 1
                try entry(text, level: level, into: &result)
            }
            return result
        }
        mutating func sequence(_ level: Int) throws -> [Any] {
            var result: [Any] = []
            while true {
                try skip()
                guard index < lines.count else { break }
                let depth = try indent(lines[index])
                let text = try clean(lines[index])
                guard depth == level && isList(text) else { break }
                let item = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                index += 1
                if item.isEmpty {
                    try skip()
                    if index < lines.count, try indent(lines[index]) > level {
                        result.append(try node(indent(lines[index])))
                    } else { result.append("") }
                } else if try colon(item) != nil {
                    var map: [String: Any] = [:]
                    try entry(item, level: level + 2, into: &map)
                    try skip()
                    if index < lines.count, try indent(lines[index]) > level {
                        guard try indent(lines[index]) == level + 2 else { throw failure("unexpected list mapping indentation") }
                        let rest = try mapping(level + 2)
                        for (key, value) in rest {
                            guard map[key] == nil else { throw failure("duplicate key \(key)") }
                            map[key] = value
                        }
                    }
                    result.append(map)
                } else { result.append(try scalar(item)) }
            }
            return result
        }
        mutating func entry(_ text: String, level: Int, into result: inout [String: Any]) throws {
            guard let split = try colon(text) else { throw failure("expected key: value") }
            let rawKey = String(text[..<split]).trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty, rawKey != "<<", let key = try scalar(rawKey) as? String else { throw failure("unsupported mapping key") }
            guard result[key] == nil else { throw failure("duplicate key \(key)") }
            let raw = String(text[text.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("|") || raw.hasPrefix(">") {
                guard ["|", "|-", "|+", ">", ">-", ">+"].contains(raw) else { throw failure("unsupported block scalar header") }
                result[key] = try block(raw, parent: level)
            } else if !raw.isEmpty { result[key] = try scalar(raw) }
            else {
                try skip()
                if index < lines.count {
                    let depth = try indent(lines[index])
                    let nextIsList = isList(try clean(lines[index]))
                    if depth > level || (depth == level && nextIsList) {
                        result[key] = try node(depth)
                        return
                    }
                }
                result[key] = ""
            }
        }
        mutating func block(_ header: String, parent: Int) throws -> String {
            var content: [String] = []
            var depth: Int?
            while index < lines.count {
                let line = lines[index]
                let spaces = try indent(line)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if spaces <= parent { break }
                    if depth == nil { depth = spaces }
                    guard spaces >= depth! else { throw failure("inconsistent block indentation") }
                }
                content.append(line.isEmpty ? "" : String(line.dropFirst(min(depth ?? spaces, line.count))))
                index += 1
            }
            var value = ""
            for i in content.indices {
                value += content[i]
                if i + 1 < content.count {
                    let fold = header.first == ">" && !content[i].isEmpty && !content[i + 1].isEmpty && !content[i].hasPrefix(" ") && !content[i + 1].hasPrefix(" ")
                    // In a folded scalar a run of k blank lines between two folded lines is k newlines, not k + 1:
                    // the text line before the run contributes none of its own.
                    let intoBlankRun = header.first == ">" && !content[i].isEmpty && !content[i].hasPrefix(" ") && content[i + 1].isEmpty
                        && content[(i + 1)...].first(where: { !$0.isEmpty }).map { !$0.hasPrefix(" ") } == true
                    value += intoBlankRun ? "" : (fold ? " " : "\n")
                }
            }
            if header.hasSuffix("-") { while value.hasSuffix("\n") { value.removeLast() } }
            else if header.hasSuffix("+") { if !content.isEmpty { value += "\n" } }
            else { while value.hasSuffix("\n") { value.removeLast() }; if !content.isEmpty { value += "\n" } }
            return value
        }
    }
}
