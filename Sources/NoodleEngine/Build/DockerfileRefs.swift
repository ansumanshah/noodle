import Foundation

/// Finds the external images a Dockerfile names (`FROM`, `COPY --from`, `--mount from=`), so the Mac can resolve them
/// before BuildKit does. This is a scanner, not a parser: it follows ARG defaults, build args and stage names.
enum DockerfileRefs {
    static func externalImages(in text: String, args overrides: [String: String]) -> [String] {
        var globals: [String: String] = [:]
        var stages = Set<String>()
        var seenFrom = false
        var found: [String] = []
        func add(_ raw: String) {
            let ref = expand(raw, globals)
            guard !ref.isEmpty, !ref.contains("$"), ref.lowercased() != "scratch", !stages.contains(ref.lowercased()),
                  !ref.allSatisfy(\.isNumber), !found.contains(ref) else { return }
            found.append(ref)
        }
        for line in logicalLines(text) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = words.first?.uppercased() else { continue }
            switch head {
            case "ARG" where !seenFrom:
                for word in words.dropFirst() {
                    let kv = word.split(separator: "=", maxSplits: 1).map(String.init)
                    guard let name = kv.first else { continue }
                    globals[name] = overrides[name] ?? (kv.count > 1 ? unquote(kv[1]) : "")
                }
            case "FROM":
                seenFrom = true
                let rest = Array(words.dropFirst().filter { !$0.hasPrefix("--") })
                guard let image = rest.first else { continue }
                add(image)
                if rest.count >= 3, rest[1].uppercased() == "AS" { stages.insert(rest[2].lowercased()) }
            case "COPY", "ADD", "RUN":
                for word in words.dropFirst() where word.hasPrefix("--") {
                    if word.hasPrefix("--from=") { add(String(word.dropFirst(7))) }
                    if word.hasPrefix("--mount=") {
                        for part in word.dropFirst(8).split(separator: ",") where part.hasPrefix("from=") { add(String(part.dropFirst(5))) }
                    }
                }
            default: break
            }
        }
        return found
    }

    /// Joins backslash continuations and drops comments and blank lines.
    static func logicalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var pending = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") { pending += String(line.dropLast()) + " "; continue }
            lines.append(pending + line)
            pending = ""
        }
        if !pending.isEmpty { lines.append(pending) }
        return lines
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// `$VAR`, `${VAR}`, `${VAR:-x}`, `${VAR-x}`, `${VAR:+x}`, `${VAR+x}`. Unknown names stay marked with `$` so callers can skip them.
    static func expand(_ s: String, _ vars: [String: String]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "$", s.index(after: i) < s.endIndex else { out.append(c); i = s.index(after: i); continue }
            let next = s[s.index(after: i)]
            if next == "{", let close = s[i...].firstIndex(of: "}") {
                let body = String(s[s.index(i, offsetBy: 2)..<close])
                var name = body, op: String?, word = ""
                for candidate in [":-", ":+", "-", "+"] {
                    if let r = body.range(of: candidate) {
                        name = String(body[..<r.lowerBound]); op = candidate; word = String(body[r.upperBound...]); break
                    }
                }
                let value = vars[name]
                let set = value?.isEmpty == false
                switch op {
                case ":-": out += set ? value! : expand(word, vars)
                case "-": out += value ?? expand(word, vars)
                case ":+": out += set ? expand(word, vars) : ""
                case "+": out += value != nil ? expand(word, vars) : ""
                default: out += value ?? "$"
                }
                i = s.index(after: close)
            } else if next.isLetter || next == "_" {
                var j = s.index(after: i)
                var name = ""
                while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" { name.append(s[j]); j = s.index(after: j) }
                out += vars[name] ?? "$"
                i = j
            } else { out.append(c); i = s.index(after: i) }
        }
        return out
    }
}
