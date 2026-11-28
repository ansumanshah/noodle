import Foundation

/// What this Mac's shell and Docker environment mean for setup, as pure functions over text the caller read.

extension SetupPlan {
    // MARK: Docker selection

    /// Lines that run: no blanks, no comments.
    static func codeLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func assigns(_ key: String, in text: String) -> Bool {
        codeLines(text).contains { $0.hasPrefix(key + "=") || $0.hasPrefix("export " + key + "=") }
    }

    /// The variable that makes plain `docker` ignore the context saved in Docker's config, if any.
    /// It counts when set in this environment or exported by a startup file.
    public static func dockerOverride(environment: [String: String], profileTexts: [String]) -> String? {
        let keys = ["DOCKER_CONTEXT", "DOCKER_HOST"]
        if let key = keys.first(where: { !(environment[$0] ?? "").isEmpty }) { return key }
        return keys.first { key in profileTexts.contains { assigns(key, in: $0) } }
    }

    /// The engine `docker` talks to, in Docker's own order: DOCKER_CONTEXT, then DOCKER_HOST, then the saved context.
    /// DOCKER_HOST names the context with the same socket when there is one, else "default".
    public static func currentContext(environment: [String: String], saved: String?, hostSocket: String?,
                                      contexts: [(name: String, socket: String)]) -> String {
        if let name = environment["DOCKER_CONTEXT"], !name.isEmpty { return name }
        if let host = environment["DOCKER_HOST"], !host.isEmpty {
            return contexts.first { $0.socket == hostSocket }?.name ?? "default"
        }
        return saved.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    }

    // MARK: terminal PATH

    static let pathBlockStart = "# >>> Noodle PATH >>>"
    static let pathBlockEnd = "# <<< Noodle PATH <<<"

    /// Conservative proof, not a shell interpreter. Unrecognised assignments and control flow need the optional step.
    static func putsOnPath(_ text: String) -> Bool {
        var proven = false
        for raw in codeLines(text) {
            let line = raw.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
            if uncertainShellLine(line) { return false }
            let assignment = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            if assignment.hasPrefix("PATH=") {
                let value = String(assignment.dropFirst(5))
                proven = ["$HOME/.local/bin", "${HOME}/.local/bin", "~/.local/bin"].contains { bin in
                    let values = [bin, bin + ":$PATH", bin + ":${PATH}", "$PATH:" + bin, "${PATH}:" + bin]
                    return values.contains(value) || (!bin.hasPrefix("~") && values.contains { "\"" + $0 + "\"" == value })
                }
            } else if assignment.hasPrefix("path=") || assignment.hasPrefix("path+=") {
                proven = ["path+=(~/.local/bin)", "path+=($HOME/.local/bin)"].contains(assignment)
            }
        }
        return proven
    }

    private static func uncertainShellLine(_ line: String) -> Bool {
        let first = line.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).first ?? ""
        return ["if", "case", "for", "while", "until", "function", "return", "exit", "exec"].contains(first)
            || line.contains("{") && !line.contains("${") || line.contains("<<") || line.hasPrefix("(")
    }

    /// True when Noodle's marked block is present and its PATH line would run.
    public static func hasPathBlock(_ text: String) -> Bool {
        guard let start = text.range(of: pathBlockStart),
              let end = text.range(of: pathBlockEnd, range: start.upperBound..<text.endIndex) else { return false }
        return putsOnPath(String(text[start.upperBound..<end.lowerBound]))
    }

    /// Whether `text` loads `file` (`. ~/.profile`, `source ~/.bashrc`, `[ -f x ] && . x`). Mentioning it is not enough.
    static func sources(_ file: String, in text: String) -> Bool {
        for line in codeLines(text) {
            for path in ["~/" + file, "$HOME/" + file, "${HOME}/" + file, "\"$HOME/" + file + "\"", "\"${HOME}/" + file + "\""] {
                for command in [". " + path, "source " + path] {
                    if [command, command + ";", "[ -f " + path + " ] && " + command,
                        "if [ -f " + path + " ]; then " + command + "; fi"].contains(line) { return true }
                }
            }
            if uncertainShellLine(line) { return false }
        }
        return false
    }

    /// The startup files a login shell in Terminal really reads, in effect. `files` maps a file name to its text.
    /// Bash reads only the first of .bash_profile, .bash_login and .profile, and .bashrc only when something sources it.
    /// A shell Noodle cannot edit reads nothing it can prove.
    public static func loginTexts(shell: String, files: [String: String]) -> [String] {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh":
            return [".zshenv", ".zprofile", ".zshrc"].compactMap { files[$0] }
        case "bash":
            guard let first = [".bash_profile", ".bash_login", ".profile"].first(where: { files[$0] != nil }) else { return [] }
            func expand(_ name: String, seen: Set<String>) -> String {
                guard !seen.contains(name), let text = files[name] else { return "" }
                var lines: [String] = [], trusted = true
                for line in text.components(separatedBy: .newlines) {
                    if trusted, let source = [".profile", ".bashrc", ".bash_profile", ".bash_login"].first(where: {
                        files[$0] != nil && sources($0, in: line)
                    }) {
                        lines.append(expand(source, seen: seen.union([name])))
                        continue
                    }
                    if uncertainShellLine(line) { trusted = false }
                    lines.append(line)
                }
                return lines.joined(separator: "\n")
            }
            return [expand(first, seen: [])]
        default:
            return []
        }
    }

    /// A new Terminal needs the PATH step unless a file its shell reads puts ~/.local/bin on PATH.
    public static func pathNeeded(shell: String, files: [String: String]) -> Bool {
        pathNeeded(profileTexts: loginTexts(shell: shell, files: files))
    }

    // MARK: terminal command

    /// The `noodle setup` line that makes the same choices as the assistant, with the flags that work on this Mac.
    public static func terminalCommand(cli: String, download: Bool, addPath: Bool, useDefault: Bool) -> String {
        func quote(_ text: String) -> String {
            if text.allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }) { return text }
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let executable = cli.hasPrefix("~/") ? "~/" + quote(String(cli.dropFirst(2))) : quote(cli)
        return ([executable] + flags(download: download, addPath: addPath, useDefault: useDefault)).joined(separator: " ")
    }
}

/// What `noodle import <source> --all` reported on its last line: "done: 3 copied, 2 unchanged or skipped, 0 failed".
/// Per-item lines separate unchanged from skipped when available; a summary alone keeps them combined.
public struct ImportOutcome: Sendable, Equatable {
    public var copied: Int, unchanged: Int, failed: Int
    /// Nil when only the combined CLI summary is available. Otherwise `unchanged` excludes skipped items.
    public var skipped: Int?
    public init(copied: Int, unchanged: Int, failed: Int, skipped: Int? = nil) {
        self.copied = copied; self.unchanged = unchanged; self.failed = failed; self.skipped = skipped
    }

    public static func parse(_ output: String) -> ImportOutcome? {
        guard let regex = try? NSRegularExpression(pattern: #"done: (\d+) copied, (\d+) unchanged or skipped, (\d+) failed"#),
              let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last else { return nil }
        let numbers = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: output) else { return nil }
            return Int(output[range])
        }
        guard numbers.count == 3 else { return nil }
        let lines = output.components(separatedBy: .newlines)
        // The summary groups these together, but the per-item lines distinguish them.
        func count(_ verdict: String) -> Int {
            lines.filter { line in
                ["image ", "volume ", "container "].contains(where: line.hasPrefix) && line.contains(": " + verdict)
            }.count
        }
        let unchanged = count("already"), skipped = count("skipped")
        if unchanged + skipped == numbers[1], numbers[1] > 0 {
            return ImportOutcome(copied: numbers[0], unchanged: unchanged, failed: numbers[2], skipped: skipped)
        }
        return ImportOutcome(copied: numbers[0], unchanged: numbers[1], failed: numbers[2])
    }

    private static func items(_ count: Int) -> String { "\(count) \(count == 1 ? "item" : "items")" }

    /// One plain line for the finished page, from the real counts.
    public func note(from engine: String) -> String {
        if let skipped {
            var parts = [copied > 0 ? "Copied \(Self.items(copied)) from \(engine)." : "No items were copied from \(engine)."]
            if unchanged > 0 { parts.append("\(Self.items(unchanged)) \(unchanged == 1 ? "was" : "were") already there.") }
            if skipped > 0 { parts.append("Skipped \(Self.items(skipped)).") }
            return parts.joined(separator: " ")
        }
        let left = unchanged == 1 ? "1 was already there or skipped." : "\(unchanged) were already there or skipped."
        switch (copied > 0, unchanged > 0) {
        case (true, false): return "Copied \(Self.items(copied)) from \(engine)."
        case (true, true): return "Copied \(Self.items(copied)) from \(engine). \(left)"
        case (false, true): return "Nothing new to copy from \(engine). \(left)"
        case (false, false): return "\(engine) had nothing to copy."
        }
    }
}
