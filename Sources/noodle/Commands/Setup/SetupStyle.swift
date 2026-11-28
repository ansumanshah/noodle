import Foundation

/// How `noodle setup` reads in a terminal. Piped output (the app, scripts, tests) keeps the plain lines untouched;
/// this only restyles them for a person, so every plain line stays the one source of what setup did.
enum SetupStyle {
    enum Line: Equatable {
        /// One aligned status row: a mark, a short label and what happened.
        case row(mark: Character, label: String, text: String)
        /// The closing line with the command to try.
        case ready(text: String, command: String)
        /// A tip printed after everything else.
        case tip(String)
    }

    static func line(_ raw: String, home: String) -> Line {
        let s = raw.replacingOccurrences(of: "unix://", with: "").replacingOccurrences(of: home, with: "~")
        if let r = s.range(of: "Try: ", options: .backwards), s.hasPrefix("Setup complete") || s.contains("then try: ") {
            let lead = s.contains("noodle start") ? "Ready. Run `noodle start`, then try" : "Ready. Try"
            return .ready(text: lead, command: String(s[r.upperBound...]))
        }
        if let r = s.range(of: "then try: ") { return .ready(text: "Ready. Run `noodle start`, then try", command: String(s[r.upperBound...])) }
        if s.hasPrefix("export ") { return .row(mark: " ", label: "", text: "  " + s) }
        if s == "Running" || s == "Already running" { return .row(mark: "✓", label: "engine", text: s.lowercased()) }
        if s.hasPrefix("Build local Dockerfiles with ") { return .tip("Build images with `docker --context noodle build .`") }
        if s.hasPrefix("CLI retained for removal") { return .tip("Remove Noodle later with `noodle uninstall`") }
        if s.hasPrefix("linked kubectl into ") { return .row(mark: "✓", label: "kubectl", text: "linked into " + s.dropFirst("linked kubectl into ".count)) }
        if s.hasPrefix("Docker context currently selected: ") {
            return .row(mark: "✓", label: "selected", text: String(s.dropFirst("Docker context currently selected: ".count)))
        }
        if s.hasPrefix("Docker context: ") {
            return .row(mark: "✓", label: "context", text: s.dropFirst("Docker context: ".count).replacingOccurrences(of: "->", with: "→"))
        }
        // "name: what happened" and "name 1.2.3: what happened".
        if let colon = s.range(of: ": "), !s[..<colon.lowerBound].contains("`") {
            let head = s[..<colon.lowerBound].split(separator: " ")
            var text = String(s[colon.upperBound...])
            if head.count <= 2, let name = head.first {
                if text.hasPrefix("using ") { text.removeFirst("using ".count) }
                if text == "ready to download on first use" { return .row(mark: "·", label: String(name), text: "downloads on first use") }
                if head.count == 2 { text = "\(head[1]), \(text)" }
                return .row(mark: text.hasSuffix("downloading") ? "↓" : "✓", label: String(name), text: text)
            }
        }
        return .row(mark: "·", label: "", text: s)
    }

    static func render(_ line: Line, color: Bool) -> String {
        func paint(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        switch line {
        case .row(let mark, let label, let text):
            let tone = mark == "✓" ? "32" : mark == "↓" ? "36" : "2"
            let name = label.padding(toLength: max(label.count, 16), withPad: " ", startingAt: 0)
            return "  " + paint(tone, String(mark)) + " " + (label.isEmpty ? text : paint("1", name) + " " + text)
        case .ready(let text, let command): return "\n  " + paint("1", text) + "  " + paint("36", command)
        case .tip(let tip): return "  " + paint("2", tip)
        }
    }

    /// Restyles everything `out` prints until the returned closure runs, which prints the held tips.
    static func begin(home: String) -> () -> Void {
        let color = env["NO_COLOR"] == nil && env["TERM"] != "dumb"
        var tips: [String] = []
        print(color ? "\n  \u{1B}[1mNoodle setup\u{1B}[0m\n" : "\n  Noodle setup\n")
        outFilter = { raw in
            for part in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                let styled = line(String(part), home: home)
                if case .tip = styled { tips.append(render(styled, color: color)) } else { print(render(styled, color: color)) }
            }
        }
        return {
            outFilter = nil
            if !tips.isEmpty { print("\n" + tips.joined(separator: "\n")) }
            print("")
        }
    }
}
