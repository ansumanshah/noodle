import Foundation

// The one list of user-facing commands. `noodle help`, `noodle <group> help` and `noodle help --json`
// are all rendered from it, and a unit test checks every dispatched command is present.

struct CLIGroup {
    let name: String
    let summary: String
    /// Prose printed under the group's command rows, for rules the rows cannot carry.
    var notes: [String] = []
}

struct CLICommand {
    let group: String
    /// Subcommand, or nil when the group is itself the command (`status`, `start`).
    let sub: String?
    let summary: String
    /// Positional arguments as written in usage, such as `<owner/repo>` or `[NAME]`.
    let args: String
    /// Flags as written in usage, such as `--json` or `--port PORT`.
    let flags: [String]
    let json: Bool
    let prompts: Bool

    var synopsis: String {
        ([sub ?? group, args].filter { !$0.isEmpty } + flags.map { "[\($0)]" }).joined(separator: " ")
    }
}

private func row(_ left: String, _ summary: String) -> String {
    "  " + left.padding(toLength: max(left.count, 40), withPad: " ", startingAt: 0) + "  " + summary
}

enum CommandTable {
    static func entries(_ group: String) -> [CLICommand] { commandList.filter { $0.group == group } }

    /// True for commands with named subcommands (`runners`), false for single commands (`status`).
    static func hasSubcommands(_ name: String) -> Bool { entries(name).contains { $0.sub != nil } }

    static func topLevelHelp(version: String) -> String {
        var lines = ["noodle \(version): small Docker-compatible runtime for macOS", "", "Usage: noodle <command>"]
        for g in commandGroups {
            let items = entries(g.name)
            let subs = items.compactMap(\.sub).joined(separator: "|")
            // Groups that also run bare (`proxy`, `link`) show the sub-commands as optional.
            let left = items.count == 1 && items[0].sub == nil
                ? items[0].synopsis
                : g.name + " " + (items.contains { $0.sub == nil } ? "[\(subs)]" : subs)
            lines.append(row(left, g.summary))
        }
        lines += ["",
                  "Run `noodle <command> help` for the flags of each command, or `noodle help --json` for a machine-readable list.",
                  "Exit codes: 0 ok, 1 failed, 2 usage error or a confirmation needed with no terminal and no --yes, 3 engine not running.", "",
                  "Use Docker for containers, images, builds and Compose:",
                  "  docker --context noodle run -d -p 8080:80 nginx",
                  "  docker --context noodle build -t example .",
                  "  docker --context noodle compose up -d"]
        return lines.joined(separator: "\n")
    }

    static func groupHelp(_ group: String) -> String {
        let summary = commandGroups.first { $0.name == group }?.summary ?? ""
        let single = hasSubcommands(group) ? nil : entries(group).first
        var lines = ["noodle \(group): \(summary)", "", "Usage: noodle " + (single?.synopsis ?? "\(group) <command>")]
        for c in entries(group) {
            lines.append(row(c.synopsis, c.summary + (c.prompts ? " (asks first; --yes skips)" : "")))
        }
        let notes = commandGroups.first { $0.name == group }?.notes ?? []
        if !notes.isEmpty { lines += [""] + notes }
        return lines.joined(separator: "\n")
    }

    /// `noodle help --json`, schemaVersion 1.
    static func helpJSON(version: String) throws -> Data {
        struct Doc: Encodable {
            struct Command: Encodable {
                let group: String, subcommand: String?, summary: String, args: String, flags: [String], json: Bool, prompts: Bool
            }
            struct Group: Encodable { let name: String, summary: String }
            let schemaVersion = 1
            let version: String
            let exitCodes: [String: String]
            let groups: [Group]
            let commands: [Command]
        }
        let doc = Doc(version: version,
                      exitCodes: ["0": "success", "1": "the operation failed", "2": "usage error, a confirmation needed with no terminal and no --yes, or (scan --fail-on) a finding at or above the threshold",
                                  "3": "the engine is not running or not reachable"],
                      groups: commandGroups.map { .init(name: $0.name, summary: $0.summary) },
                      commands: commandList.map { .init(group: $0.group, subcommand: $0.sub, summary: $0.summary, args: $0.args,
                                                         flags: $0.flags, json: $0.json, prompts: $0.prompts) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }
}
