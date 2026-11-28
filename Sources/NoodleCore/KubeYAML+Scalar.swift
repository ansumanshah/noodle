import Foundation

extension KubeYAML.Parser {
    /// A quote starts a quoted scalar only where a scalar can start: at the beginning, or after
    /// whitespace that follows `[ { , : -`. An apostrophe inside a plain scalar (`don't`) is just text.
    func opensQuote(_ text: String, at i: String.Index) -> Bool {
        var j = i
        while j > text.startIndex {
            j = text.index(before: j)
            if text[j].isWhitespace { continue }
            switch text[j] {
            case "[", "{", ",", ":": return true
            case "-": return text.index(after: j) != i   // a dash starts a list item only when a space follows
            default: return false
            }
        }
        return true
    }
    // Scan punctuation only outside quotes and flow collections.
    func scan(_ text: String, separator: Character) throws -> [String.Index] {
        var quote: Character?; var escaped = false; var depth = 0; var positions: [String.Index] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q {
                    let next = text.index(after: i)
                    if q == "'", next < text.endIndex, text[next] == "'" { i = next }
                    else { quote = nil }
                }
            } else if (c == "\"" || c == "'") && opensQuote(text, at: i) { quote = c }
            else if c == "[" || c == "{" { depth += 1; if depth > Self.maxNesting { throw failure("nesting is deeper than \(Self.maxNesting) levels") } }
            else if c == "]" || c == "}" { depth -= 1; if depth < 0 { throw failure("unbalanced flow collection") } }
            else if c == separator && depth == 0 { positions.append(i) }
            i = text.index(after: i)
        }
        guard quote == nil && depth == 0 else { throw failure("unterminated quote or flow collection") }
        return positions
    }
    func colon(_ text: String) throws -> String.Index? {
        try scan(text, separator: ":").first { i in
            let next = text.index(after: i)
            return next == text.endIndex || text[next].isWhitespace
        }
    }
    func clean(_ line: String) throws -> String {
        // Comments do not require parsing the remainder (which may contain unmatched quotes).
        var quote: Character?; var escaped = false; var previous: Character?; var skipNext = false
        for i in line.indices {
            let c = line[i]
            if skipNext { skipNext = false; previous = c; continue }
            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q {
                    let next = line.index(after: i)
                    if q == "'", next < line.endIndex, line[next] == "'" { skipNext = true } else { quote = nil }
                }
            } else if c == "#" && (previous == nil || previous!.isWhitespace) {
                return String(line[..<i]).trimmingCharacters(in: .whitespaces)
            } else if (c == "'" || c == "\"") && opensQuote(line, at: i) { quote = c }
            previous = c
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
    func scalar(_ raw: String) throws -> Any {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        if text.first == "[" || text.first == "{" {
            guard (text.first == "[" && text.last == "]") || (text.first == "{" && text.last == "}") else { throw failure("malformed flow collection") }
            let body = String(text.dropFirst().dropLast())
            let cuts = try scan(body, separator: ",")
            var items: [String] = []; var start = body.startIndex
            for cut in cuts { items.append(String(body[start..<cut])); start = body.index(after: cut) }
            if !body[start...].trimmingCharacters(in: .whitespaces).isEmpty { items.append(String(body[start...])) }
            if text.first == "[" { return try items.map { try scalar($0) } }
            var map: [String: Any] = [:]
            for item in items {
                guard let cut = try scan(item, separator: ":").first else { throw failure("malformed flow mapping") }
                guard let key = try scalar(String(item[..<cut])) as? String, !key.isEmpty, key != "<<", map[key] == nil else { throw failure("invalid or duplicate flow key") }
                map[key] = try scalar(String(item[item.index(after: cut)...]))
            }
            return map
        }
        if text.first == "\"" {
            guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: data) else { throw failure("invalid quoted scalar") }
            return value
        }
        if text.first == "'" {
            guard text.count >= 2, text.last == "'" else { throw failure("invalid quoted scalar") }
            let body = String(text.dropFirst().dropLast())
            guard !body.replacingOccurrences(of: "''", with: "").contains("'") else { throw failure("invalid single quote escape") }
            return body.replacingOccurrences(of: "''", with: "'")
        }
        guard !["&", "*", "!", "%", "?", "|", ">", "@", "`"].contains(String(text.prefix(1))) else { throw failure("unsupported YAML scalar") }
        _ = try scan(text, separator: "\0")
        return text
    }
}
